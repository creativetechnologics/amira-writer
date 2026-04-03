# 116 — Combined Engine Critical-Path Summary

Date: 2026-03-31

## Purpose
Distill the combined dependency graph into the work packages most likely to block overall implementation progress.

## Principle
Not every package matters equally.
The critical-path summary should highlight the dependency chain that most strongly determines how fast the future engine can advance.

## What to extract
- longest dependency chain
- packages on that chain
- early choke points
- first opportunities for parallel relief

## Why this matters
The dependency graph is complete, but too broad for fast prioritization.
The critical-path summary answers:

> “If engineering can only push a few things first, what most reduces schedule risk?”

## Reporting rule
The summary should identify:
- the critical-path package list
- the first 3 highest-priority packages
- any parallel packages that can proceed without extending the chain

## Engineering use
Use the critical-path summary to:
- prioritize staffing
- sequence implementation starts
- avoid spending time on non-blocking side work too early
