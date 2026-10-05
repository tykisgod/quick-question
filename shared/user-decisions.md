# Decisions That Belong to the User

Three kinds of item are the user's call, never the agent's.

- **Protection:** something exempt from a rule everything else follows (cannot be hit, cannot be destroyed, keeps a minimum, skipped by targeting).
- **Added restriction:** a rule whose purpose is to stop, or make costlier, a player choice the other rules allow (anti-exploit rules, "to prevent the player from X", e.g. refusing a one-sided trade). Not this kind: how a new thing works (where it can be placed, what it needs, what it connects to), or a gate without which the game crashes or gets stuck. Blocking a choice because the numbers come out wrong is not a gate: fix the numbers.
- **Scope cut:** delivering less than the user's request: dropping part of it, deferring it out of the plan, or replacing it with a smaller or different version. Putting work into a later milestone of the same plan is not a cut.

Everything else (ordinary rules, numbers, technical choices) is the agent's call and needs no tag.

## What counts as the user's words

- An inline quote right after the item: `(user: "<their exact words>")`.
- A citation that quotes them and that you can open. It must cover this item; a decision stretched to a new case does not count.
- A document the user wrote themselves.

Not the user's words: "the author's call", a decision-journal entry without their words, an earlier doc that does not quote them, "the user approved this section", a blanket note such as "unmarked lines are the user's".

## When there are no user's words

1. If the user is in the conversation, ask about the item by name and quote the answer inline. An OK to a whole section is not an answer about the item.
2. Otherwise (`--auto`, the user is away, or the question is left open), put it on the **Needs the user's decision** list and keep going. Never wait for the answer.
3. Until it is answered, build the normal rule: no protection, no added restriction, and a cut item stays in scope.
4. A bug whose only fix you can see is a protection or an added restriction goes on the list too, with the bug and the proposed fix.
5. Repeat new entries in your summary or handoff.

## The list

- It sits at the top of the design doc (in the plan, if there is no design doc), under the heading `## Needs the user's decision`. Keep that heading in English, verbatim, so every skill finds it.
- One plain `- ` bullet per item, never `- [ ]`: `/qq:execute` ticks unchecked boxes.
- A plan copies its design doc's list as is.
