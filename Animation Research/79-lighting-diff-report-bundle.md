# 79 — Lighting Diff Report Bundle

Date: 2026-03-31

## Purpose
Define the review bundle for lighting channel fixtures and duet motion-lighting fixtures.

## Bundle contents
A lighting diff bundle should contain:
- old hero location profile channel fixture JSON
- new hero location profile channel fixture JSON
- old duet motion-lighting packet JSON
- new duet motion-lighting packet JSON
- `lighting_fixture_diff_report.json`
- `lighting_fixture_diff_report.md`

## Regression classes
Block on:
- missing profile families
- missing hero location bindings
- missing required channels
- missing duet packet coverage
- missing packet fixture links
- insufficient beat coverage

Warn on:
- default profile changes
- routing downgrades
- reduced beat count above threshold

## Handoff expectation
The engineer handoff packet should carry two generated examples:
- a passing lighting diff bundle
- a regressed lighting diff bundle
