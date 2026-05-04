import json
import os
import sys

COVERAGE_THRESHOLD = 82


def calculate_coverage(file_path):
    if not os.path.exists(file_path):
        print("No deployment result found — no test classes were run, skipping coverage check.")
        sys.exit(0)

    with open(file_path, 'r') as file:
        data = json.load(file)

    # Extract coverage array from sf project deploy start --json output
    try:
        coverage_list = data['result']['details']['runTestResult']['codeCoverage']
    except (KeyError, TypeError):
        print("No code coverage data found in the deployment result.")
        sys.exit(0)

    if not coverage_list:
        print("Coverage list is empty — no Apex classes were covered.")
        sys.exit(0)

    total_lines = 0
    covered_lines = 0
    failed_classes = []

    print(f"=== Per-Class Coverage Report (threshold: {COVERAGE_THRESHOLD}%) ===")
    for entry in coverage_list:
        name = entry.get('name', 'Unknown')
        # numLocations and numLocationsNotCovered are strings in sf deploy JSON
        num_locations = int(entry.get('numLocations', 0))
        num_not_covered = int(entry.get('numLocationsNotCovered', 0))

        if num_locations == 0:
            continue

        covered = num_locations - num_not_covered
        pct = (covered / num_locations) * 100
        status = "PASS" if pct >= COVERAGE_THRESHOLD else "FAIL"
        print(f"  [{status}] {name}: {pct:.2f}% ({covered}/{num_locations} lines)")

        total_lines += num_locations
        covered_lines += covered

        if pct < COVERAGE_THRESHOLD:
            failed_classes.append((name, pct, covered, num_locations))

    overall = (covered_lines / total_lines) * 100 if total_lines > 0 else 0

    print(f"\n=== Coverage Summary ===")
    print(f"  Current org-wide : {overall:.2f}%")
    print(f"  Required          : {COVERAGE_THRESHOLD}%")
    print(f"  Classes passed    : {len(coverage_list) - len(failed_classes)}/{len(coverage_list)}")

    if failed_classes:
        print(f"\n=== Classes below {COVERAGE_THRESHOLD}% threshold ===")
        for name, pct, covered, total in failed_classes:
            print(f"  {name}: {pct:.2f}% ({covered}/{total} lines covered) — needs {COVERAGE_THRESHOLD - pct:.2f}% more")
        print(f"\nCOVERAGE GATE FAILED: Fix test coverage before this PR can be merged.")
        sys.exit(1)

    print(f"\nCOVERAGE GATE PASSED: All classes meet the {COVERAGE_THRESHOLD}% minimum.")


if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else 'deploy-result.json'
    calculate_coverage(file_path)