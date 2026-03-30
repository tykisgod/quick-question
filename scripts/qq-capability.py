#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


DEFAULT_REGISTRY_PATH = Path(__file__).resolve().with_name("qq-capabilities.json")


def load_registry(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def emit(payload: dict[str, Any], pretty: bool) -> int:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if pretty else None, sort_keys=pretty)
    sys.stdout.write("\n")
    return 0


def validate_registry(registry: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    capabilities = registry.get("capabilities") or {}
    engine_adapters = registry.get("engineAdapters") or {}
    host_adapters = registry.get("hostAdapters") or {}
    transport_adapters = registry.get("transportAdapters") or {}
    providers = registry.get("providers") or {}
    preferred = ((registry.get("resolution") or {}).get("preferredProviders") or {})

    if not isinstance(capabilities, dict) or not capabilities:
        errors.append("capabilities must be a non-empty object")
    if not isinstance(providers, dict) or not providers:
        errors.append("providers must be a non-empty object")

    for provider_id, provider in providers.items():
        if not isinstance(provider, dict):
            errors.append(f"provider {provider_id} must be an object")
            continue

        engine_adapter = provider.get("engineAdapter")
        transport_adapter = provider.get("transportAdapter")
        if engine_adapter not in engine_adapters:
            errors.append(f"provider {provider_id} references unknown engineAdapter: {engine_adapter}")
        if transport_adapter not in transport_adapters:
            errors.append(f"provider {provider_id} references unknown transportAdapter: {transport_adapter}")

        for host in provider.get("hostAdapters") or []:
            if host not in host_adapters:
                errors.append(f"provider {provider_id} references unknown hostAdapter: {host}")

        for capability in provider.get("capabilities") or []:
            if capability not in capabilities:
                errors.append(f"provider {provider_id} references unknown capability: {capability}")

        for capability in (provider.get("toolMappings") or {}).keys():
            if capability not in capabilities:
                errors.append(f"provider {provider_id} has tool mapping for unknown capability: {capability}")

    for engine, engine_mappings in preferred.items():
        if engine not in engine_adapters:
            errors.append(f"resolution references unknown engineAdapter: {engine}")
            continue
        for capability, provider_ids in (engine_mappings or {}).items():
            if capability not in capabilities:
                errors.append(f"resolution for engine {engine} references unknown capability: {capability}")
            for provider_id in provider_ids or []:
                if provider_id not in providers:
                    errors.append(f"resolution for {engine}/{capability} references unknown provider: {provider_id}")
                    continue
                provider_engine = providers[provider_id].get("engineAdapter")
                if provider_engine != engine:
                    errors.append(
                        f"resolution for {engine}/{capability} references provider {provider_id} from engine {provider_engine}"
                    )

    return errors


def list_capabilities(registry: dict[str, Any]) -> list[dict[str, Any]]:
    return [{"id": capability_id, **(definition or {})} for capability_id, definition in sorted((registry.get("capabilities") or {}).items())]


def list_providers(
    registry: dict[str, Any],
    engine: str | None = None,
    capability: str | None = None,
    host: str | None = None,
    transport: str | None = None,
) -> list[dict[str, Any]]:
    providers = registry.get("providers") or {}
    items: list[dict[str, Any]] = []
    for provider_id, definition in sorted(providers.items()):
        if engine and definition.get("engineAdapter") != engine:
            continue
        if transport and definition.get("transportAdapter") != transport:
            continue
        if capability and capability not in (definition.get("capabilities") or []):
            continue
        if host and host not in (definition.get("hostAdapters") or []):
            continue
        items.append({"id": provider_id, **definition})
    return items


def describe_capability(registry: dict[str, Any], capability: str) -> dict[str, Any]:
    capabilities = registry.get("capabilities") or {}
    definition = capabilities.get(capability)
    if definition is None:
        raise KeyError(f"Unknown capability: {capability}")

    preferred_by_engine: dict[str, list[str]] = {}
    for engine, mappings in ((registry.get("resolution") or {}).get("preferredProviders") or {}).items():
        providers = (mappings or {}).get(capability) or []
        if providers:
            preferred_by_engine[engine] = providers

    supporting_providers = [item["id"] for item in list_providers(registry, capability=capability)]
    return {
        "id": capability,
        **definition,
        "preferredProviders": preferred_by_engine,
        "supportingProviders": supporting_providers,
    }


def describe_provider(registry: dict[str, Any], provider_id: str) -> dict[str, Any]:
    providers = registry.get("providers") or {}
    definition = providers.get(provider_id)
    if definition is None:
        raise KeyError(f"Unknown provider: {provider_id}")
    return {"id": provider_id, **definition}


def resolve_provider(
    registry: dict[str, Any],
    capability: str,
    engine: str,
    available: list[str] | None = None,
) -> dict[str, Any]:
    resolution = ((registry.get("resolution") or {}).get("preferredProviders") or {})
    engine_mappings = resolution.get(engine) or {}
    ordered = list(engine_mappings.get(capability) or [])
    if not ordered:
        raise KeyError(f"No preferred providers configured for {engine}/{capability}")

    available_set = set(available or ordered)
    chosen = next((provider_id for provider_id in ordered if provider_id in available_set), None)
    if chosen is None:
        return {
            "capability": capability,
            "engine": engine,
            "resolved": None,
            "availableProviders": sorted(available_set),
            "preferredProviders": ordered,
            "message": "No preferred provider available",
        }

    return {
        "capability": capability,
        "engine": engine,
        "resolved": chosen,
        "availableProviders": sorted(available_set),
        "preferredProviders": ordered,
        "provider": describe_provider(registry, chosen),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq capability registry helper")
    parser.add_argument("--registry", default=str(DEFAULT_REGISTRY_PATH), help="Path to qq capability registry JSON")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate", help="Validate registry consistency")
    validate_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    list_caps_parser = subparsers.add_parser("list-capabilities", help="List known capabilities")
    list_caps_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    providers_parser = subparsers.add_parser("list-providers", help="List known providers")
    providers_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    providers_parser.add_argument("--engine", help="Filter by engine adapter")
    providers_parser.add_argument("--capability", help="Filter by capability")
    providers_parser.add_argument("--host", help="Filter by host adapter")
    providers_parser.add_argument("--transport", help="Filter by transport adapter")

    capability_parser = subparsers.add_parser("describe-capability", help="Describe one capability")
    capability_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    capability_parser.add_argument("capability")

    provider_parser = subparsers.add_parser("describe-provider", help="Describe one provider")
    provider_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    provider_parser.add_argument("provider")

    resolve_parser = subparsers.add_parser("resolve", help="Resolve the preferred provider for a capability")
    resolve_parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    resolve_parser.add_argument("--capability", required=True)
    resolve_parser.add_argument("--engine", default=None, help="Engine adapter to resolve against")
    resolve_parser.add_argument(
        "--available",
        nargs="*",
        default=None,
        help="Optional available provider ids. When omitted, uses registry preference order.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    registry = load_registry(Path(args.registry).resolve())

    if args.command == "validate":
        errors = validate_registry(registry)
        emit({"ok": not errors, "errors": errors}, args.pretty)
        return 0 if not errors else 1

    if args.command == "list-capabilities":
        return emit({"capabilities": list_capabilities(registry)}, args.pretty)

    if args.command == "list-providers":
        providers = list_providers(
            registry,
            engine=args.engine,
            capability=args.capability,
            host=args.host,
            transport=args.transport,
        )
        return emit({"providers": providers}, args.pretty)

    if args.command == "describe-capability":
        try:
            payload = {"capability": describe_capability(registry, args.capability)}
        except KeyError as exc:
            emit({"ok": False, "error": str(exc)}, args.pretty)
            return 1
        return emit(payload, args.pretty)

    if args.command == "describe-provider":
        try:
            payload = {"provider": describe_provider(registry, args.provider)}
        except KeyError as exc:
            emit({"ok": False, "error": str(exc)}, args.pretty)
            return 1
        return emit(payload, args.pretty)

    if args.command == "resolve":
        engine = args.engine or registry.get("defaultEngine") or "unity"
        try:
            payload = resolve_provider(registry, args.capability, engine, args.available)
        except KeyError as exc:
            emit({"ok": False, "error": str(exc)}, args.pretty)
            return 1
        emit(payload, args.pretty)
        return 0 if payload.get("resolved") else 1

    parser.error(f"Unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
