# Graph Report - minilist  (2026-10-08)

## Corpus Check
- Corpus is ~5,336 words - fits in a single context window. You may not need a graph.

## Summary
- 49 nodes · 83 edges · 6 communities (5 shown, 1 thin omitted)
- Extraction: 81% EXTRACTED · 19% INFERRED · 0% AMBIGUOUS · INFERRED: 16 edges (avg confidence: 0.9)
- Token cost: 99,019 input · 0 output

## Community Hubs (Navigation)
- App Shell & Admin
- Product Import & Transfer
- Routing & Owner Dashboard
- Public Baby Page
- Translation Layer
- Vercel Config

## God Nodes (most connected - your core abstractions)
1. `pextras() dashboard extras` - 16 edges
2. `go() hash router` - 15 edges
3. `panel() owner dashboard` - 12 edges
4. `pub() public baby page` - 10 edges
5. `extras() public page sections` - 5 edges
6. `hero() page header and fruit size` - 5 edges
7. `addRows() bulk product insert` - 5 edges
8. `nav() hash navigation` - 5 edges
9. `u() safe http URL filter` - 5 edges
10. `admin() admin page list` - 4 edges

## Surprising Connections (you probably didn't know these)
- `go() hash router` --implements--> `Page transfer (devral) invite flow`  [INFERRED]
  index.html → index.html  _Bridges community 2 → community 1_
- `panel() owner dashboard` --shares_data_with--> `addRows() bulk product insert`  [INFERRED]
  index.html → index.html  _Bridges community 2 → community 0_
- `go() hash router` --calls--> `pub() public baby page`  [EXTRACTED]
  index.html → index.html  _Bridges community 2 → community 3_
- `pextras() dashboard extras` --calls--> `addRows() bulk product insert`  [EXTRACTED]
  index.html → index.html  _Bridges community 1 → community 0_
- `pextras() dashboard extras` --calls--> `plink() public page link`  [EXTRACTED]
  index.html → index.html  _Bridges community 1 → community 3_

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Hash-routed views dispatched by go()** — index_go, index_home, index_panel, index_pub, index_admin, index_legal [EXTRACTED 1.00]
- **TR->EN translation pipeline** — index_d, index_p, index_t, index_tl, index_pref [INFERRED 0.95]
- **Bulk product import flow (starter list, Amazon bookmarklet, pasted lines)** — index_starter, index_bkm, index_parselines, index_namefromurl, index_addrows [INFERRED 0.95]

## Communities (6 total, 1 thin omitted)

### Community 0 - "App Shell & Admin"
Cohesion: 0.20
Nodes (10): addRows() bulk product insert, admin() admin page list, book() memory book PDF, e() HTML escape, err() error alert helper, home() landing page, nav() hash navigation, out() sign out (+2 more)

### Community 1 - "Product Import & Transfer"
Cohesion: 0.29
Nodes (8): BKM Amazon wishlist bookmarklet, isU() URL check, parseLines() import parser, pextras() dashboard extras, sga() accept product suggestion, STARTER sample baby list, tp() admin create transfer, u() safe http URL filter

### Community 2 - "Routing & Owner Dashboard"
Cohesion: 0.27
Nodes (10): dp() delete product, dx() generic row delete, ep() edit product, go() hash router, legal() privacy/terms view, LG legal texts (privacy, terms), mkslug() random slug generator, panel() owner dashboard (+2 more)

### Community 3 - "Public Baby Page"
Cohesion: 0.29
Nodes (10): dueFromWeek(), extras() public page sections, FR weekly fruit size table, Guest RPC API (guest_reserve, guest_suggest, guest_letter, guest_product_suggest, heart), gwk() gestational week from due date, hero() page header and fruit size, plink() public page link, pub() public baby page (+2 more)

### Community 4 - "Translation Layer"
Cohesion: 0.33
Nodes (5): D TR=>EN translation dictionary, L() inline bilingual picker, P regex translation patterns, T() translate string, tl() DOM text translation walker

## Knowledge Gaps
- **10 isolated node(s):** `headers`, `tick() countdown timer`, `LG legal texts (privacy, terms)`, `recover() password reset`, `mkslug() random slug generator` (+5 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 13 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `pextras() dashboard extras` connect `Product Import & Transfer` to `App Shell & Admin`, `Routing & Owner Dashboard`, `Public Baby Page`?**
  _High betweenness centrality (0.333) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `pextras() dashboard extras` (e.g. with `Page transfer (devral) invite flow` and `sga() accept product suggestion`) actually correct?**
  _`pextras() dashboard extras` has 3 INFERRED edges - model-reasoned connections that need verification._
- **What connects `headers`, `tick() countdown timer`, `LG legal texts (privacy, terms)` to the rest of the system?**
  _10 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Why does `go() hash router` connect `Routing & Owner Dashboard` to `App Shell & Admin`, `Product Import & Transfer`, `Public Baby Page`?**
  _High betweenness centrality (0.328) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `panel() owner dashboard` (e.g. with `addRows() bulk product insert` and `ep() edit product`) actually correct?**
  _`panel() owner dashboard` has 3 INFERRED edges - model-reasoned connections that need verification._
- **Why does `hero() page header and fruit size` connect `Public Baby Page` to `Translation Layer`?**
  _High betweenness centrality (0.264) - this node is a cross-community bridge._