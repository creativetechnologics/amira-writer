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
]


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: combined_engine_release_promotion_report.py <release-targets.json> <outputs-dir>')
        return 2

    targets = load_json(Path(sys.argv[1]))
    outputs_root = Path(sys.argv[2])

    reports = {}
    missing_reports: list[str] = []
    for report_name in REQUIRED_REPORTS:
        report_path = outputs_root / report_name
        if not report_path.exists():
            missing_reports.append(report_name)
            continue
        reports[report_name] = load_json(report_path)

    program_gate = reports.get('combined_engine_program_gate.json', {})
    band_exit = reports.get('combined_engine_band_exit_report.json', {})
    risk = reports.get('combined_engine_risk_report.json', {})
    contingency = reports.get('combined_engine_contingency_report.json', {})
    change_impact = reports.get('combined_engine_change_impact_report.json', {})
    impl_test = reports.get('combined_engine_implementation_test_matrix_report.json', {})

    highest_ready_band = program_gate.get('highestContiguousReadyBand')
    ready_bands = set(program_gate.get('readyBands', []))
    exit_ready_lookup = {item.get('bandId'): item.get('exitReady', False) for item in band_exit.get('bandStatuses', [])}
    band_playbooks = {item.get('bandId'): item for item in contingency.get('bandPlaybooks', []) if item.get('bandId')}
    risk_entries_by_band: dict[str, list[dict]] = {}
    for item in risk.get('riskRegister', []):
        risk_entries_by_band.setdefault(item.get('bandId', ''), []).append(item)
    impact_rows_by_band: dict[str, list[dict]] = {}
    for item in change_impact.get('impactMatrix', []):
        for band_id in item.get('reopenedBands', []):
            impact_rows_by_band.setdefault(band_id, []).append(item)
    test_rows_by_band: dict[str, list[dict]] = {}
    for item in impl_test.get('testMatrix', []):
        test_rows_by_band.setdefault(item.get('bandId', ''), []).append(item)

    ordered_bands = targets.get('targetBands', [])
    promotion_checklist = []
    promotion_ready_bands = []
    blocked_bands = []

    for band_id in ordered_bands:
        blockers: list[str] = []
        warnings: list[str] = []
        required_reports = list(REQUIRED_REPORTS)
        exit_ready = exit_ready_lookup.get(band_id, False)
        program_gate_ready = band_id in ready_bands
        risk_reviewed = risk.get('valid', False) and bool(risk_entries_by_band.get(band_id))
        contingency_ready = contingency.get('valid', False) and band_id in band_playbooks
        change_impact_ready = change_impact.get('valid', False) and bool(impact_rows_by_band.get(band_id))
        band_test_rows = test_rows_by_band.get(band_id, [])
        implementation_test_ready = impl_test.get('valid', False) and bool(band_test_rows) and all(row.get('ready', False) for row in band_test_rows)

        if missing_reports:
            blockers.append(f'Missing required reports: {", ".join(sorted(missing_reports))}.')
        if not exit_ready:
            blockers.append('Band-exit gate is not ready for this band.')
        if not program_gate_ready:
            blockers.append('Combined program gate is not contiguous through this band.')
        if not contingency_ready:
            blockers.append('No contingency playbook entry exists for this band.')
        if not implementation_test_ready:
            blockers.append('Implementation test matrix is not fully ready for this band.')
        if not risk_reviewed:
            blockers.append('Risk register coverage is missing for this band.')
        if not change_impact_ready:
            blockers.append('Change-impact coverage is missing for this band.')

        band_risks = risk_entries_by_band.get(band_id, [])
        high_risks = [item for item in band_risks if item.get('riskLevel') in {'critical', 'high'}]
        if high_risks:
            warnings.append(f'{len(high_risks)} high-severity risk entries remain documented for this band.')
        if band_id in change_impact.get('bandsReopened', []):
            warnings.append('Band is sensitive to at least one current re-entry scenario and should be re-promoted carefully after changes.')
        if highest_ready_band == band_id and band_id == ordered_bands[-1]:
            warnings.append('This is currently the highest contiguous ready band and carries full-program promotion responsibility.')

        promotion_ready = not blockers
        payload = {
            'bandId': band_id,
            'promotionReady': promotion_ready,
            'exitReady': exit_ready,
            'programGateReady': program_gate_ready,
            'riskReviewed': risk_reviewed,
            'contingencyReady': contingency_ready,
            'changeImpactReady': change_impact_ready,
            'implementationTestReady': implementation_test_ready,
            'requiredReports': required_reports,
            'blockers': blockers,
            'warnings': warnings,
        }
        promotion_checklist.append(payload)
        if promotion_ready:
            promotion_ready_bands.append(band_id)
        else:
            blocked_bands.append(band_id)

    result = {
        'targetBandCount': len(ordered_bands),
        'promotionReadyBands': promotion_ready_bands,
        'blockedBands': blocked_bands,
        'promotionChecklist': promotion_checklist,
        'valid': not blocked_bands,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
