# Ticket interface design

## Overview

A one-page interface for people exploring the Sepolia hourly swap lottery. The implemented direction uses a warm paper background, dark ink, an oversized serif heading, and a lime ticket-shaped pot panel. The pot and trade form lead; round management, claims, winners and explanations follow in DOM order. The page repeatedly identifies the experiment as a test with no value or promised return.

Implementation sources: `web/src/styles.css` contains all tokens and responsive rules; `web/src/App.tsx` supplies semantic markup, state and the small SVG ticket mark. The deliberate light theme uses no image service, webfonts or external design assets. This document lives under `docs/` because root `DESIGN.md` is outside the allowed write scope.

## Colors

Primitives and semantic aliases are defined together at `web/src/styles.css:1`. Components use semantic aliases.

| Token | Value | Use |
| --- | --- | --- |
| `--color-page` | `#f5f3ec` | Page background |
| `--color-surface` | `#fcfbf7` | Cards, fields and secondary buttons |
| `--color-subtle` | `#ebe8de` | Claim panel and segmented-control track |
| `--color-text` | `#23271f` | Text, focus ring, selected outlines |
| `--color-muted` | `#626459` | Descriptions and captions |
| `--color-line` | `#b6b5a9` | Structural borders |
| `--color-accent` | `#e4f298` | Primary action and pot/ticket brand surface |
| `--color-accent-hover` | `#d1e678` | Primary hover |
| `--color-success` | `#47612f` | Live status indicator |
| `--color-danger` | `#8b3026` | Errors |
| `--color-danger-bg` | `#fff0eb` | Error surface |

Color is accompanied by text, borders or selected/disabled semantics. “Get quote” is the filled action; approval, trade confirmation, seal, draw and claim use outlined buttons. Static lime surfaces carry the ticket identity, with no suggestion that the whole pot card is clickable. No gradients or dark theme are implemented.

Measured rendered text contrast: ink on lime 12.63:1; ink on page 13.69:1; muted on surface 5.82:1; muted on claim panel 4.91:1; muted on page 5.42:1. Exact sampled pairs are in `docs/evidence/accessibility.json`. These are measured pairs, not a claim about every state or platform.

## Typography

- Body/UI: `Arial, Helvetica, sans-serif`, 16px root, unitless 1.55 line-height. Regular and bold/semibold weights use system fonts. No font files are downloaded; the platform resolves the fallback family. The worker checked computed stacks, not specific installed font-file identity.
- Main heading: `Georgia, 'Times New Roman', serif`, 400 with an italic second line, `clamp(2.8rem, 5.4vw, 4.8rem)`, line-height 1.04 and tracking `-.055em`. At 35rem and below it becomes `clamp(2.4rem, 10vw, 3.5rem)`.
- Section headings: `--text-section: clamp(1.75rem, 3vw, 2.5rem)`, line-height 1.18. Card headings are 1.125rem; small-screen card titles 1rem.
- UI roles: body 1rem, small `.875rem`, caption `.8125rem`. Metadata/eyebrows use `.7rem` with explicit uppercase styling and letter spacing. Amount input is 1.75rem; other inputs remain at least 1rem/16px on mobile.
- Pot amount: responsive 2.75–4.8rem on desktop, 4rem intermediate, 3rem narrow; units are smaller. Countdown, amounts and counts use tabular numerals. Dust below display precision is shown with `<`, rather than as zero.
- Headings balance wrapping; prose uses `text-wrap: pretty`. Long explanations cap at 75ch. Addresses/hashes in deployment details wrap; shortened address links expose the full destination, and the full connected wallet is available in the details disclosure.

## Layout

The shared `.site-shell` caps at 1264px, centered with 32px desktop gutters. Spacing variables are `.5`, `1`, `1.5`, `2`, `3` and `5rem`. Section separation is 5rem desktop and 3rem narrow. Primary/secondary grids use a `1.35fr / 1fr` split and 24px gap, with `minmax(0, …)` to prevent intrinsic overflow.

| Breakpoint | Behavior |
| --- | --- |
| 64rem | Header compresses, duplicate network badge hides, grids use `1.1fr / 1fr` |
| 49rem | Pot/trade and management/claim stack; navigation moves to its own row; 20px gutters; section headings stack; winner rows become two columns |
| 35rem | 16px gutters; intro note stacks; three-step explanation becomes one column; history footer stacks; round picker wraps; deployment details become one column |

The top-level reading order matches the DOM at every width. Primary controls stay in normal document flow. Button rows wrap; no sticky panels, modals or hidden horizontal carousels are used. Screenshots and overflow checks cover 1440, 768, 390 and 320 CSS pixels. A 200% root-text enlargement check passed at 1440px; this is not browser-native zoom.

## Elevation & depth

The interface is deliberately flat. Borders identify panels, field boundaries, selected trade direction and section divisions. The decorative ticket has a hard offset two-layer shadow, producing a stack of paper tickets. There are no overlay elevations or blurred surfaces.

## Shapes

Cards use 10–12px radii, fields/inner surfaces 6–8px, and compact status pills 100px. The ticket mark is one inline SVG using `currentColor`, a 2px stroke and a dashed perforation. The ticket illustration rotates -5 degrees; the brand mark -7 degrees. These are static decoration and hidden from assistive technology.

## Components

These are application patterns in `App.tsx`, not a separate component library:

| Pattern / class | Role and behavior |
| --- | --- |
| `External` | Descriptive explorer links with a decorative arrow, full href, and `noreferrer` |
| `TicketMark` | Reused decorative inline SVG; inherits color |
| `.button`, `.primary`, `.text-button` | 44px minimum controls, 48px main buttons; outlined/filled/text variants; real disabled states |
| `.segmented` | Two native buttons with `aria-pressed`; keyboard Tab/Enter/Space works without a custom tab widget |
| `.amount-box`, `.receive-box`, `.limit-row` | Labeled input, separate output estimate and bounded price setting; field errors reference the input and focus the amount field |
| `.pot-card`, `.round-metrics` | Chain pot, tickets, wallet entries and quiet countdown; does not announce every second |
| `.round-panel` | Round lookup, lifecycle guidance and eligibility-gated seal/draw/rollover controls |
| `.claim-panel` | Shows winnings and disables claim unless funds are available to the connected wallet |
| `.transaction-region`, `.error-banner` | Stable polite status region, persistent errors, submitted hash and explicit recovery controls |
| `.winner-row`, `.empty-history` | Event-derived winners or explanatory empty state, plus visible query coverage and older-page action |
| Native `details`/`summary` | Optional mechanism/deployment detail without a custom overlay or focus trap |

Keyboard focus is a 3px ink outline with 4px offset, using `Highlight` in forced colors. A skip link is first in DOM. Hover styles apply only when hover is supported. Button background/press transitions last 120ms and only apply under `prefers-reduced-motion: no-preference`; press scale is `.96`. There is no autoplay or entrance animation.

## Do's and don'ts

- Start another section with the shared shell, section heading, semantic heading hierarchy and existing grid/panel patterns. Use the same CSS roles before introducing a new token.
- Keep test-network context, exact action consequences, token units and error recovery visible. Let balances determine action availability.
- Keep a single filled primary action in the trade section. Retain adjacent explanatory text for disabled controls.
- Let labels wrap, preserve 16px inputs and test at 320px after content changes. Avoid a fixed-width address or action row.
- Do not imply guaranteed returns, guaranteed quote output, authenticated ticket identity, automatic draws, or a production-grade random source.
- Rebuild the deployment inventory after changing any export asset.

Design-review coverage and unperformed checks are recorded separately in `docs/validation.md`. Pinned reference attribution is in `docs/ATTRIBUTION.md`.
