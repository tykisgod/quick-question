# tykit README Section — Design Spec

## Goal

Add a dedicated tykit section to README.md that:
1. Positions tykit as an independent tool any AI agent can use
2. Shows how quick-question leverages it
3. Provides standalone installation instructions

## Location

Between "Quick Start" and "Commands" sections, as a top-level heading.

## Structure

### 1. Header + One-liner
`## tykit — Unity Editor HTTP Server`
One sentence: tykit is a standalone HTTP server inside Unity Editor that lets any AI agent control compilation, testing, Play Mode, and more.

### 2. Standalone Install
One code block: add one line to `Packages/manifest.json`. No need for quick-question.

### 3. Scenario-based Use Cases (3-4)
Each use case: scenario description + curl command + expected output.
- Run tests and get results
- Control Play Mode
- Read console errors
- Find and inspect GameObjects

### 4. Full API Reference Table
All commands in a table: command name, args, description.

### 5. How quick-question Uses tykit
One paragraph: auto-compile hook tries tykit first (fast, non-blocking), tests run via tykit, this is why quick-question is faster than batch mode.

### 6. Architecture Diagram (Mermaid)
Move existing Claude Code <-> tykit <-> Unity Editor diagram from How It Works to here.

## Changes to Existing Content

- How It Works > "tykit" subsection: replace with one sentence + link to new section
- How It Works > Auto-Compilation Mermaid: keep (shows fallback logic, different from tykit architecture diagram)
- Chinese section: sync all changes

## No Changes To

- C# code
- Shell scripts
- Other README sections
