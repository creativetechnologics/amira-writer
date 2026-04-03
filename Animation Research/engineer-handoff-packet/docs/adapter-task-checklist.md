# 44 — Engineer Adapter Task Checklists

Date: 2026-03-31

## Purpose
Break the future adapter work into explicit engineering checklists.

## PackageManifestAdapter checklist
- decode vNext package manifest
- resolve default costume pack
- resolve default mouth profile
- verify master/head/body sheet ids exist
- surface coverage metadata to the caller

## MotionPlanAdapter checklist
- decode sparse motion plan
- validate character ids against package ids
- validate primitive ids exist
- emit runtime-safe motion instructions
- report plan issues without crashing playback

## MouthOverlayAdapter checklist
- decode mouth profile
- decode lyric/speech mouth plan
- resolve angle-family anchor
- emit ordered mouth overlay events
- support speech first, singing second

## AssetReviewAdapter checklist
- decode review JSON
- expose approve/edit/regenerate/escalate
- expose promotion eligibility
- preserve review history identity

## ReadinessAdapter checklist
- compute readiness score
- compute readiness status
- expose missing-coverage reasons
- support routing bridge inputs

## First pilot checklist
- load Luke hero-ready package fixture
- load Luke pilot packet fixture
- validate packet + package + mouth profile + motion plan
- confirm routing remains internal
- confirm pilot assets are sufficient for one dialogue shot
