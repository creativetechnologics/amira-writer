#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def run_json(cmd: list[str]) -> dict:
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.stdout.strip():
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {'raw': result.stdout, 'returncode': result.returncode}
    return {'returncode': result.returncode}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: build_handoff_outputs.py <research-root>')
        return 2
    root = Path(sys.argv[1])
    handoff = root / 'engineer-handoff-packet'
    outputs = handoff / 'outputs'
    outputs.mkdir(parents=True, exist_ok=True)

    inventory = run_json(['python3', str(root / 'tools' / 'handoff_fixture_inventory.py'), str(handoff / 'fixtures')])
    audit = run_json(['python3', str(root / 'tools' / 'handoff_bundle_audit.py'), str(handoff)])
    lighting_profile = run_json(['python3', str(root / 'tools' / 'lighting_profile_report.py'), str(root / 'examples' / 'sample_lighting_profile.json')])
    motion_plan_lint = run_json(['python3', str(root / 'tools' / 'motion_plan_linter.py'), str(root / 'examples' / 'sample_walk_and_sing_motion_plan.json')])
    mouth_timing = run_json(['python3', str(root / 'tools' / 'mouth_timing_validator.py'), str(root / 'examples' / 'sample_lyric_mouth_plan.json')])
    mouth_preset_report = run_json(['python3', str(root / 'tools' / 'mouth_preset_report.py'), str(root / 'examples' / 'sample_detailed_mouth_presets.json')])
    readiness_bridge = run_json(['python3', str(root / 'tools' / 'readiness_routing_bridge.py'), '--readiness', 'performance-ready', '--complexity', '8', '--revision-sensitivity', '7'])
    shot_library = run_json(['python3', str(root / 'tools' / 'shot_library_report.py'), str(root / 'examples' / 'sample_action_ensemble_shots.json')])
    pilot_packet = run_json(['python3', str(root / 'tools' / 'pilot_packet_check.py'), str(root / 'examples' / 'sample_pilot_packet.json')])
    lighting_library = run_json(['python3', str(root / 'tools' / 'lighting_profile_library_check.py'), str(root / 'examples' / 'sample_lighting_profile_library.json')])
    lighting_plan = run_json(['python3', str(root / 'tools' / 'lighting_plan_check.py'), str(root / 'examples' / 'sample_shot_lighting_plan.json')])
    lighting_review = run_json(['python3', str(root / 'tools' / 'lighting_review_gate.py'), str(root / 'examples' / 'sample_lighting_review.json')])
    lighting_seed = run_json(['python3', str(root / 'tools' / 'script_lighting_seed.py'), str(root / 'examples' / 'sample_script_lighting_cues.json')])
    lighting_seed_complex = run_json(['python3', str(root / 'tools' / 'script_lighting_seed.py'), str(root / 'examples' / 'sample_script_lighting_cues_complex.json')])
    beat_lighting_seed = run_json(['python3', str(root / 'tools' / 'script_lighting_beat_seed.py'), str(root / 'examples' / 'sample_script_lighting_beat_cues.json'), str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json')])
    beat_lighting_check = run_json(['python3', str(root / 'tools' / 'script_lighting_beat_plan_check.py'), str(root / 'examples' / 'sample_script_lighting_beat_plan.json')])
    beat_lighting_continuity = run_json(['python3', str(root / 'tools' / 'beat_lighting_continuity_check.py'), str(root / 'examples' / 'sample_script_lighting_beat_plan.json')])
    beat_lighting_readiness = run_json(['python3', str(root / 'tools' / 'beat_lighting_readiness_report.py'), str(root / 'examples' / 'sample_beat_lighting_readiness_fixture.json')])
    beat_lighting_readiness_regressed = run_json(['python3', str(root / 'tools' / 'beat_lighting_readiness_report.py'), str(root / 'examples' / 'sample_beat_lighting_readiness_fixture_regressed.json')])
    ensemble_beat_lighting_readiness = run_json(['python3', str(root / 'tools' / 'ensemble_beat_lighting_readiness_report.py'), str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture.json')])
    ensemble_beat_lighting_readiness_regressed = run_json(['python3', str(root / 'tools' / 'ensemble_beat_lighting_readiness_report.py'), str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture_regressed.json')])
    lighting_materials = run_json(['python3', str(root / 'tools' / 'lighting_material_audit.py'), str(root / 'examples' / 'sample_material_response_catalog.json')])
    lighting_readiness = run_json(['python3', str(root / 'tools' / 'lighting_readiness_report.py'), str(root / 'examples' / 'sample_luke_lighting_ready_package.json'), str(root / 'examples' / 'sample_clinic_location_lighting_set.json')])
    lighting_routing = run_json(['python3', str(root / 'tools' / 'lighting_routing_case_check.py'), str(root / 'examples' / 'sample_lighting_aware_routing_cases.json')])
    key_locations = run_json(['python3', str(root / 'tools' / 'location_lighting_set_check.py'), str(root / 'examples' / 'sample_key_location_lighting_sets.json')])
    hero_location_usage = run_json(['python3', str(root / 'tools' / 'hero_location_usage_report.py'), str(root / 'examples' / 'sample_hero_location_usage_matrix.json')])
    side_by_side = run_json(['python3', str(root / 'tools' / 'side_by_side_lighting_bundle_check.py'), str(root / 'examples' / 'sample_side_by_side_lighting_pilot_bundles.json')])
    hero_reads = run_json(['python3', str(root / 'tools' / 'hero_lighting_read_report.py'), str(root / 'examples' / 'sample_hero_lighting_read_comparison.json')])
    duet_packets = run_json(['python3', str(root / 'tools' / 'duet_lighting_packet_check.py'), str(root / 'examples' / 'sample_duet_lighting_pilot_packets.json')])
    duet_reads = run_json(['python3', str(root / 'tools' / 'duet_lighting_read_report.py'), str(root / 'examples' / 'sample_duet_lighting_read_matrix.json')])
    duet_location_plans = run_json(['python3', str(root / 'tools' / 'duet_location_plan_index_check.py'), str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json')])
    location_zone_practical = run_json(['python3', str(root / 'tools' / 'location_lighting_zone_practical_check.py'), str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json')])
    hero_profile_channels = run_json(['python3', str(root / 'tools' / 'hero_location_profile_channel_check.py'), str(root / 'examples' / 'sample_hero_location_profile_channels.json')])
    duet_motion_packets = run_json(['python3', str(root / 'tools' / 'duet_motion_lighting_packet_check.py'), str(root / 'examples' / 'sample_duet_motion_lighting_packets.json')])
    duet_routing_comparisons = run_json(['python3', str(root / 'tools' / 'duet_routing_comparison_report.py'), str(root / 'examples' / 'sample_duet_routing_comparisons.json')])
    ensemble_routing_comparisons = run_json(['python3', str(root / 'tools' / 'ensemble_routing_comparison_report.py'), str(root / 'examples' / 'sample_ensemble_routing_comparisons.json')])
    ensemble_zone_practical_stress = run_json(['python3', str(root / 'tools' / 'ensemble_zone_practical_stress_report.py'), str(root / 'examples' / 'sample_ensemble_zone_practical_stress_cases.json')])
    ensemble_layer_consistency = run_json(['python3', str(root / 'tools' / 'ensemble_layer_consistency_report.py'), str(root / 'examples' / 'sample_ensemble_layer_consistency_cases.json')])
    ensemble_layer_consistency_regressed = run_json(['python3', str(root / 'tools' / 'ensemble_layer_consistency_report.py'), str(root / 'examples' / 'sample_ensemble_layer_consistency_cases_regressed.json')])
    lighting_engine_milestones = run_json(['python3', str(root / 'tools' / 'lighting_engine_milestone_report.py'), str(root / 'examples' / 'sample_lighting_engine_milestone_map.json')])
    mouth_engine_milestones = run_json(['python3', str(root / 'tools' / 'mouth_engine_milestone_report.py'), str(root / 'examples' / 'sample_mouth_engine_milestone_map.json')])
    combined_engine_rollout = run_json(['python3', str(root / 'tools' / 'combined_engine_rollout_report.py'), str(root / 'examples' / 'sample_combined_engine_rollout_matrix.json')])
    combined_engine_program_gate = run_json(['python3', str(root / 'tools' / 'combined_engine_program_gate.py'), str(root / 'examples' / 'sample_combined_engine_rollout_matrix.json'), str(root)])
    combined_engine_band_exit = run_json(['python3', str(root / 'tools' / 'combined_engine_band_exit_gate.py'), str(root / 'examples' / 'sample_combined_engine_rollout_matrix.json'), str(root)])
    combined_engine_change_impact = run_json(['python3', str(root / 'tools' / 'combined_engine_change_impact_report.py'), str(root / 'examples' / 'sample_combined_engine_change_events.json'), str(root / 'examples' / 'sample_combined_engine_rollout_matrix.json'), str(root / 'examples' / 'sample_combined_engine_work_packages.json')])
    combined_engine_test_matrix = run_json(['python3', str(root / 'tools' / 'combined_engine_implementation_test_matrix_report.py'), str(root / 'examples' / 'sample_combined_engine_change_classes.json'), str(root / 'examples' / 'sample_combined_engine_rollout_matrix.json'), str(root)])
    combined_engine_work_packages = run_json(['python3', str(root / 'tools' / 'combined_engine_work_package_report.py'), str(root / 'examples' / 'sample_combined_engine_work_packages.json')])
    combined_engine_staffing = run_json(['python3', str(root / 'tools' / 'combined_engine_staffing_report.py'), str(root / 'examples' / 'sample_combined_engine_staffing_map.json'), str(root / 'examples' / 'sample_combined_engine_work_packages.json')])
    combined_engine_dependency = run_json(['python3', str(root / 'tools' / 'combined_engine_dependency_report.py'), str(root / 'examples' / 'sample_combined_engine_work_packages.json')])
    combined_engine_critical_path = run_json(['python3', str(root / 'tools' / 'combined_engine_critical_path_report.py'), str(root / 'examples' / 'sample_combined_engine_work_packages.json')])
    combined_engine_risk = run_json(['python3', str(root / 'tools' / 'combined_engine_risk_report.py'), str(root / 'examples' / 'sample_combined_engine_work_packages.json'), str(root / 'examples' / 'sample_combined_engine_staffing_map.json')])
    acceptance = run_json(['python3', str(root / 'tools' / 'acceptance_matrix_check.py'), str(root / 'examples' / 'sample_acceptance_matrix.json')])

    (outputs / 'fixture_inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    (outputs / 'handoff_audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    (outputs / 'lighting_profile_report.json').write_text(json.dumps(lighting_profile, indent=2) + '\n')
    (outputs / 'motion_plan_linter.json').write_text(json.dumps(motion_plan_lint, indent=2) + '\n')
    (outputs / 'mouth_timing_validator.json').write_text(json.dumps(mouth_timing, indent=2) + '\n')
    (outputs / 'mouth_preset_report.json').write_text(json.dumps(mouth_preset_report, indent=2) + '\n')
    (outputs / 'readiness_routing_bridge.json').write_text(json.dumps(readiness_bridge, indent=2) + '\n')
    (outputs / 'shot_library_report.json').write_text(json.dumps(shot_library, indent=2) + '\n')
    (outputs / 'pilot_packet_check.json').write_text(json.dumps(pilot_packet, indent=2) + '\n')
    (outputs / 'lighting_profile_library_check.json').write_text(json.dumps(lighting_library, indent=2) + '\n')
    (outputs / 'lighting_plan_check.json').write_text(json.dumps(lighting_plan, indent=2) + '\n')
    (outputs / 'lighting_review_gate.json').write_text(json.dumps(lighting_review, indent=2) + '\n')
    (outputs / 'script_lighting_seed.json').write_text(json.dumps(lighting_seed, indent=2) + '\n')
    (outputs / 'script_lighting_seed_complex.json').write_text(json.dumps(lighting_seed_complex, indent=2) + '\n')
    (outputs / 'script_lighting_beat_seed.json').write_text(json.dumps(beat_lighting_seed, indent=2) + '\n')
    (outputs / 'script_lighting_beat_plan_check.json').write_text(json.dumps(beat_lighting_check, indent=2) + '\n')
    (outputs / 'beat_lighting_continuity_check.json').write_text(json.dumps(beat_lighting_continuity, indent=2) + '\n')
    (outputs / 'beat_lighting_readiness_report.json').write_text(json.dumps(beat_lighting_readiness, indent=2) + '\n')
    (outputs / 'beat_lighting_readiness_report_regressed.json').write_text(json.dumps(beat_lighting_readiness_regressed, indent=2) + '\n')
    (outputs / 'ensemble_beat_lighting_readiness_report.json').write_text(json.dumps(ensemble_beat_lighting_readiness, indent=2) + '\n')
    (outputs / 'ensemble_beat_lighting_readiness_report_regressed.json').write_text(json.dumps(ensemble_beat_lighting_readiness_regressed, indent=2) + '\n')
    (outputs / 'lighting_material_audit.json').write_text(json.dumps(lighting_materials, indent=2) + '\n')
    (outputs / 'lighting_readiness_report.json').write_text(json.dumps(lighting_readiness, indent=2) + '\n')
    (outputs / 'lighting_routing_case_check.json').write_text(json.dumps(lighting_routing, indent=2) + '\n')
    (outputs / 'key_location_lighting_set_check.json').write_text(json.dumps(key_locations, indent=2) + '\n')
    (outputs / 'hero_location_usage_report.json').write_text(json.dumps(hero_location_usage, indent=2) + '\n')
    (outputs / 'side_by_side_lighting_bundle_check.json').write_text(json.dumps(side_by_side, indent=2) + '\n')
    (outputs / 'hero_lighting_read_report.json').write_text(json.dumps(hero_reads, indent=2) + '\n')
    (outputs / 'duet_lighting_packet_check.json').write_text(json.dumps(duet_packets, indent=2) + '\n')
    (outputs / 'duet_lighting_read_report.json').write_text(json.dumps(duet_reads, indent=2) + '\n')
    (outputs / 'duet_location_plan_index_check.json').write_text(json.dumps(duet_location_plans, indent=2) + '\n')
    (outputs / 'location_lighting_zone_practical_check.json').write_text(json.dumps(location_zone_practical, indent=2) + '\n')
    (outputs / 'hero_location_profile_channel_check.json').write_text(json.dumps(hero_profile_channels, indent=2) + '\n')
    (outputs / 'duet_motion_lighting_packet_check.json').write_text(json.dumps(duet_motion_packets, indent=2) + '\n')
    (outputs / 'duet_routing_comparison_report.json').write_text(json.dumps(duet_routing_comparisons, indent=2) + '\n')
    (outputs / 'ensemble_routing_comparison_report.json').write_text(json.dumps(ensemble_routing_comparisons, indent=2) + '\n')
    (outputs / 'ensemble_zone_practical_stress_report.json').write_text(json.dumps(ensemble_zone_practical_stress, indent=2) + '\n')
    (outputs / 'ensemble_layer_consistency_report.json').write_text(json.dumps(ensemble_layer_consistency, indent=2) + '\n')
    (outputs / 'ensemble_layer_consistency_report_regressed.json').write_text(json.dumps(ensemble_layer_consistency_regressed, indent=2) + '\n')
    (outputs / 'lighting_engine_milestone_report.json').write_text(json.dumps(lighting_engine_milestones, indent=2) + '\n')
    (outputs / 'mouth_engine_milestone_report.json').write_text(json.dumps(mouth_engine_milestones, indent=2) + '\n')
    (outputs / 'combined_engine_rollout_report.json').write_text(json.dumps(combined_engine_rollout, indent=2) + '\n')
    (outputs / 'combined_engine_program_gate.json').write_text(json.dumps(combined_engine_program_gate, indent=2) + '\n')
    (outputs / 'combined_engine_band_exit_report.json').write_text(json.dumps(combined_engine_band_exit, indent=2) + '\n')
    (outputs / 'combined_engine_change_impact_report.json').write_text(json.dumps(combined_engine_change_impact, indent=2) + '\n')
    (outputs / 'combined_engine_implementation_test_matrix_report.json').write_text(json.dumps(combined_engine_test_matrix, indent=2) + '\n')
    (outputs / 'combined_engine_work_package_report.json').write_text(json.dumps(combined_engine_work_packages, indent=2) + '\n')
    (outputs / 'combined_engine_staffing_report.json').write_text(json.dumps(combined_engine_staffing, indent=2) + '\n')
    (outputs / 'combined_engine_dependency_report.json').write_text(json.dumps(combined_engine_dependency, indent=2) + '\n')
    (outputs / 'combined_engine_critical_path_report.json').write_text(json.dumps(combined_engine_critical_path, indent=2) + '\n')
    (outputs / 'combined_engine_risk_report.json').write_text(json.dumps(combined_engine_risk, indent=2) + '\n')
    combined_engine_contingency = run_json(['python3', str(root / 'tools' / 'combined_engine_contingency_report.py'), str(outputs / 'combined_engine_risk_report.json'), str(root / 'examples' / 'sample_combined_engine_work_packages.json'), str(root / 'examples' / 'sample_combined_engine_staffing_map.json')])
    (outputs / 'combined_engine_contingency_report.json').write_text(json.dumps(combined_engine_contingency, indent=2) + '\n')
    combined_engine_release_promotion = run_json(['python3', str(root / 'tools' / 'combined_engine_release_promotion_report.py'), str(root / 'examples' / 'sample_combined_engine_release_targets.json'), str(outputs)])
    (outputs / 'combined_engine_release_promotion_report.json').write_text(json.dumps(combined_engine_release_promotion, indent=2) + '\n')
    combined_engine_governance_dashboard = run_json(['python3', str(root / 'tools' / 'combined_engine_governance_dashboard_report.py'), str(outputs)])
    (outputs / 'combined_engine_governance_dashboard_report.json').write_text(json.dumps(combined_engine_governance_dashboard, indent=2) + '\n')
    (outputs / 'acceptance_matrix_check.json').write_text(json.dumps(acceptance, indent=2) + '\n')

    diff_dir = outputs / 'package-diff-example'
    diff = run_json([
        'python3', str(root / 'tools' / 'generate_package_diff_bundle.py'),
        str(root / 'examples' / 'sample_hero_ready_package.json'),
        str(root / 'examples' / 'sample_hero_ready_package_regressed.json'),
        str(diff_dir)
    ])
    lighting_diff_pass_dir = outputs / 'lighting-diff-example-passing'
    lighting_diff_pass = run_json([
        'python3', str(root / 'tools' / 'generate_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_hero_location_profile_channels.json'),
        str(root / 'examples' / 'sample_hero_location_profile_channels.json'),
        str(root / 'examples' / 'sample_duet_motion_lighting_packets.json'),
        str(root / 'examples' / 'sample_duet_motion_lighting_packets.json'),
        str(lighting_diff_pass_dir)
    ])
    lighting_diff_regressed_dir = outputs / 'lighting-diff-example-regressed'
    lighting_diff_regressed = run_json([
        'python3', str(root / 'tools' / 'generate_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_hero_location_profile_channels.json'),
        str(root / 'examples' / 'sample_hero_location_profile_channels_regressed.json'),
        str(root / 'examples' / 'sample_duet_motion_lighting_packets.json'),
        str(root / 'examples' / 'sample_duet_motion_lighting_packets_regressed.json'),
        str(lighting_diff_regressed_dir)
    ])
    zone_diff_pass_dir = outputs / 'location-lighting-zone-practical-diff-passing'
    zone_diff_pass = run_json([
        'python3', str(root / 'tools' / 'generate_location_lighting_zone_practical_diff_bundle.py'),
        str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json'),
        str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json'),
        str(zone_diff_pass_dir)
    ])
    zone_diff_regressed_dir = outputs / 'location-lighting-zone-practical-diff-regressed'
    zone_diff_regressed = run_json([
        'python3', str(root / 'tools' / 'generate_location_lighting_zone_practical_diff_bundle.py'),
        str(root / 'examples' / 'sample_duet_location_lighting_plan_index.json'),
        str(root / 'examples' / 'sample_duet_location_lighting_plan_index_regressed.json'),
        str(zone_diff_regressed_dir)
    ])
    beat_diff_pass_dir = outputs / 'beat-lighting-diff-passing'
    beat_diff_pass = run_json([
        'python3', str(root / 'tools' / 'generate_beat_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_script_lighting_beat_plan.json'),
        str(root / 'examples' / 'sample_script_lighting_beat_plan.json'),
        str(beat_diff_pass_dir)
    ])
    beat_diff_regressed_dir = outputs / 'beat-lighting-diff-regressed'
    beat_diff_regressed = run_json([
        'python3', str(root / 'tools' / 'generate_beat_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_script_lighting_beat_plan.json'),
        str(root / 'examples' / 'sample_script_lighting_beat_plan_regressed.json'),
        str(beat_diff_regressed_dir)
    ])
    ensemble_routing_diff_pass_dir = outputs / 'ensemble-routing-diff-passing'
    ensemble_routing_diff_pass = run_json([
        'python3', str(root / 'tools' / 'generate_ensemble_routing_diff_bundle.py'),
        str(root / 'examples' / 'sample_ensemble_routing_comparisons.json'),
        str(root / 'examples' / 'sample_ensemble_routing_comparisons.json'),
        str(ensemble_routing_diff_pass_dir)
    ])
    ensemble_routing_diff_regressed_dir = outputs / 'ensemble-routing-diff-regressed'
    ensemble_routing_diff_regressed = run_json([
        'python3', str(root / 'tools' / 'generate_ensemble_routing_diff_bundle.py'),
        str(root / 'examples' / 'sample_ensemble_routing_comparisons.json'),
        str(root / 'examples' / 'sample_ensemble_routing_comparisons_regressed.json'),
        str(ensemble_routing_diff_regressed_dir)
    ])
    ensemble_beat_diff_pass_dir = outputs / 'ensemble-beat-lighting-diff-passing'
    ensemble_beat_diff_pass = run_json([
        'python3', str(root / 'tools' / 'generate_ensemble_beat_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture.json'),
        str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture.json'),
        str(ensemble_beat_diff_pass_dir)
    ])
    ensemble_beat_diff_regressed_dir = outputs / 'ensemble-beat-lighting-diff-regressed'
    ensemble_beat_diff_regressed = run_json([
        'python3', str(root / 'tools' / 'generate_ensemble_beat_lighting_diff_bundle.py'),
        str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture.json'),
        str(root / 'examples' / 'sample_ensemble_beat_lighting_readiness_fixture_regressed.json'),
        str(ensemble_beat_diff_regressed_dir)
    ])

    manifest = {
        'fixtureInventory': inventory,
        'handoffAudit': audit,
        'lightingProfileReport': lighting_profile,
        'motionPlanLinter': motion_plan_lint,
        'mouthTimingValidator': mouth_timing,
        'mouthPresetReport': mouth_preset_report,
        'readinessRoutingBridge': readiness_bridge,
        'shotLibraryReport': shot_library,
        'pilotPacketCheck': pilot_packet,
        'lightingProfileLibraryCheck': lighting_library,
        'lightingPlanCheck': lighting_plan,
        'lightingReviewGate': lighting_review,
        'scriptLightingSeed': lighting_seed,
        'scriptLightingSeedComplex': lighting_seed_complex,
        'scriptLightingBeatSeed': beat_lighting_seed,
        'scriptLightingBeatPlanCheck': beat_lighting_check,
        'beatLightingContinuityCheck': beat_lighting_continuity,
        'beatLightingReadinessReport': beat_lighting_readiness,
        'beatLightingReadinessReportRegressed': beat_lighting_readiness_regressed,
        'ensembleBeatLightingReadinessReport': ensemble_beat_lighting_readiness,
        'ensembleBeatLightingReadinessReportRegressed': ensemble_beat_lighting_readiness_regressed,
        'lightingMaterialAudit': lighting_materials,
        'lightingReadinessReport': lighting_readiness,
        'lightingRoutingCaseCheck': lighting_routing,
        'keyLocationLightingSetCheck': key_locations,
        'heroLocationUsageReport': hero_location_usage,
        'sideBySideLightingBundleCheck': side_by_side,
        'heroLightingReadReport': hero_reads,
        'duetLightingPacketCheck': duet_packets,
        'duetLightingReadReport': duet_reads,
        'duetLocationPlanIndexCheck': duet_location_plans,
        'locationLightingZonePracticalCheck': location_zone_practical,
        'heroLocationProfileChannelCheck': hero_profile_channels,
        'duetMotionLightingPacketCheck': duet_motion_packets,
        'duetRoutingComparisonReport': duet_routing_comparisons,
        'ensembleRoutingComparisonReport': ensemble_routing_comparisons,
        'ensembleZonePracticalStressReport': ensemble_zone_practical_stress,
        'ensembleLayerConsistencyReport': ensemble_layer_consistency,
        'ensembleLayerConsistencyReportRegressed': ensemble_layer_consistency_regressed,
        'lightingEngineMilestoneReport': lighting_engine_milestones,
        'mouthEngineMilestoneReport': mouth_engine_milestones,
        'combinedEngineRolloutReport': combined_engine_rollout,
        'combinedEngineProgramGate': combined_engine_program_gate,
        'combinedEngineBandExitReport': combined_engine_band_exit,
        'combinedEngineChangeImpactReport': combined_engine_change_impact,
        'combinedEngineImplementationTestMatrixReport': combined_engine_test_matrix,
        'combinedEngineReleasePromotionReport': combined_engine_release_promotion,
        'combinedEngineGovernanceDashboardReport': combined_engine_governance_dashboard,
        'combinedEngineWorkPackageReport': combined_engine_work_packages,
        'combinedEngineStaffingReport': combined_engine_staffing,
        'combinedEngineDependencyReport': combined_engine_dependency,
        'combinedEngineCriticalPathReport': combined_engine_critical_path,
        'combinedEngineRiskReport': combined_engine_risk,
        'combinedEngineContingencyReport': combined_engine_contingency,
        'acceptanceMatrixCheck': acceptance,
        'packageDiffExample': diff,
        'lightingDiffPassingExample': lighting_diff_pass,
        'lightingDiffRegressedExample': lighting_diff_regressed,
        'locationLightingZonePracticalDiffPassingExample': zone_diff_pass,
        'locationLightingZonePracticalDiffRegressedExample': zone_diff_regressed,
        'beatLightingDiffPassingExample': beat_diff_pass,
        'beatLightingDiffRegressedExample': beat_diff_regressed,
        'ensembleRoutingDiffPassingExample': ensemble_routing_diff_pass,
        'ensembleRoutingDiffRegressedExample': ensemble_routing_diff_regressed,
        'ensembleBeatLightingDiffPassingExample': ensemble_beat_diff_pass,
        'ensembleBeatLightingDiffRegressedExample': ensemble_beat_diff_regressed,
    }
    (outputs / 'build_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
