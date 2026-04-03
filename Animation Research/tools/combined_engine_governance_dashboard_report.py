#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_REPORTS = [
    'combined_engine_program_gate.json',
    'combined_engine_band_exit_report.json',
    'combined_engine_risk_report.json',
    'combined_engine_contingency_report.json',
    'combined_engine_change_impact_report.json',
    'combined_engine_implementation_test_matrix_report.json',
    'combined_engine_release_promotion_report.json',
]


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: combined_engine_governance_dashboard_report.py <outputs-dir>')
        return 2

    outputs_root = Path(sys.argv[1])
    reports = {}
    missing_reports: list[str] = []
    invalid_reports: list[str] = []
    for report_name in REQUIRED_REPORTS:
        report_path = outputs_root / report_name
        if not report_path.exists():
            missing_reports.append(report_name)
            continue
        payload = load_json(report_path)
        reports[report_name] = payload
        if not payload.get('valid', False):
            invalid_reports.append(report_name)

    program_gate = reports.get('combined_engine_program_gate.json', {})
    band_exit = reports.get('combined_engine_band_exit_report.json', {})
    risk = reports.get('combined_engine_risk_report.json', {})
    contingency = reports.get('combined_engine_contingency_report.json', {})
    change_impact = reports.get('combined_engine_change_impact_report.json', {})
    impl_test = reports.get('combined_engine_implementation_test_matrix_report.json', {})
    release = reports.get('combined_engine_release_promotion_report.json', {})

    top_concerns: list[str] = []
    if missing_reports:
        top_concerns.append(f'Missing required governance reports: {", ".join(sorted(missing_reports))}.')
    if invalid_reports:
        top_concerns.append(f'Invalid governance reports: {", ".join(sorted(invalid_reports))}.')
    if release.get('blockedBands'):
        top_concerns.append(f'Promotion is blocked for bands: {", ".join(release.get("blockedBands", []))}.')
    if risk.get('programRisks'):
        severe_program_risks = [item for item in risk.get('programRisks', []) if item.get('riskLevel') in {'critical', 'high'}]
        if severe_program_risks:
            top_concerns.append(f'{len(severe_program_risks)} high-severity program risks remain active.')
    if change_impact.get('minimumReentryBand') == 'B1':
        top_concerns.append('At least one tracked change class reopens the rollout from B1.')
    if release.get('promotionReadyBands') and release.get('promotionReadyBands') == ['B1', 'B2', 'B3', 'B4', 'B5', 'B6']:
        top_concerns.append('All bands are promotable, but promotion still depends on maintaining the current artifact set.')

    if missing_reports or invalid_reports or release.get('blockedBands'):
        overall_state = 'red'
    elif top_concerns:
        overall_state = 'yellow'
    else:
        overall_state = 'green'

    result = {
        'overallState': overall_state,
        'highestContiguousReadyBand': program_gate.get('highestContiguousReadyBand'),
        'highestExitReadyBand': band_exit.get('highestExitReadyBand'),
        'promotionReadyBands': release.get('promotionReadyBands', []),
        'blockedBands': release.get('blockedBands', []),
        'highestRiskPackages': risk.get('highestRiskPackages', []),
        'programRiskIds': [item.get('riskId') for item in risk.get('programRisks', [])],
        'triggerPackageCount': len(contingency.get('triggerPackages', [])),
        'minimumReentryBand': change_impact.get('minimumReentryBand'),
        'implementationTestReady': impl_test.get('valid', False),
        'topConcerns': top_concerns,
        'valid': not missing_reports and not invalid_reports and overall_state in {'green', 'yellow', 'red'},
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
