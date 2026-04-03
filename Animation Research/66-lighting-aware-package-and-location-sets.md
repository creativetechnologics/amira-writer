# 66 — Lighting-Aware Package and Location Sets

Date: 2026-03-31

## Purpose
Describe how character packages and location sets should declare lighting compatibility.

## Character package additions
A lighting-aware character package should be able to declare:
- supported lighting profiles
- material-response tags in use
- face-protection defaults
- mouth-visibility defaults
- costume-specific lighting notes

## Location set additions
A location lighting set should declare:
- supported lighting profiles
- zone list
- practical-light anchors
- atmosphere defaults
- profile compatibility notes

## Why both matter
A shot relight is only trustworthy when both sides are known:
- what the character materials can tolerate
- what the location zones can tolerate

## Suggested first location sets
- district clinic exterior
- clinic interior fluorescent room
- rooftop at sunset
- village street at night

## Integration rule
The shot lighting plan should reference both:
- the active character package lighting data
- the active location lighting set
