# Track clearance (scenery over road/run-off) — 2026-10-31
- Probe script (not in repo): /tmp/f1probe/probe.mjs builds each world like index.html and reports any triangle 0.3-80 m over road+run-off probes (ground >0.03). Items ≥4.5 m flagged `^` (bridges/tunnels/gantry/stand roofs = legit).
- Fixes live in src/world3d.mjs: buildTerrain land() exact nearest section; post-pass clamps ground cell corners under road/run-off (0.5 m sampling); run-off `reach` stops 1.5 m before other sections, min over neighbours. stands.mjs: pit building trimmed off other parts of lap.
- As of commit after 7093312: all 19 circuits clean at car height. Full test suite ~500 s (222 tests) — run in background.
