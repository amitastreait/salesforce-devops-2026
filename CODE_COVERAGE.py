import json
import os
import sys

COVERAGE_THRESHOLD = 85

def check_component_failures(data):
    component_failures = data.get('result', {}).get('details', {}).get('componentFailures', [])
    if not component_failures:
        return False

    print(f"=== Component Failures ({len(component_failures)} error(s)) ===")
    for failure in component_failures:
        component_type = failure.get('componentType', 'Unknown')
        full_name = failure.get('fullName', 'Unknown')
        file_name = failure.get('fileName', 'Unknown')
        problem = failure.get('problem', 'No details provided')
        problem_type = failure.get('problemType', 'Error')
        print(f"  [{problem_type}] {component_type}: {full_name}")
        print(f"    File    : {file_name}")
        print(f"    Problem : {problem}")

    print(f"\nCOMPONENT FAILURE GATE FAILED: {len(component_failures)} component(s) failed to deploy.")
    return True


def check_test_failures(data):
    try:
        failures = data['result']['details']['runTestResult']['failures']
    except (KeyError, TypeError):
        return False

    if not failures:
        return False

    print(f"=== Test Failures ({len(failures)} failure(s)) ===")
    for failure in failures:
        name = failure.get('name', 'Unknown')
        method = failure.get('methodName', 'Unknown')
        message = failure.get('message', 'No message')
        stack_trace = failure.get('stackTrace', '')
        print(f"  [FAIL] {name}.{method}")
        print(f"    Message     : {message}")
        if stack_trace:
            print(f"    Stack Trace : {stack_trace}")

    print(f"\nTEST FAILURE GATE FAILED: {len(failures)} test(s) failed.")
    return True


def extract_coverage_list(data):
    try:
        return data['result']['details']['runTestResult']['codeCoverage']
    except (KeyError, TypeError):
        return None


def report_per_class_coverage(coverage_list):
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

    return total_lines, covered_lines, failed_classes


def calculate_coverage(file_path):
    if not os.path.exists(file_path):
        print("No deployment result found — no test classes were run, skipping coverage check.")
        sys.exit(0)

    with open(file_path, 'r') as file:
        data = json.load(file)

    has_failures = check_component_failures(data)
    if has_failures:
        print()

    if check_test_failures(data):
        has_failures = True
        print()

    coverage_list = extract_coverage_list(data)
    if coverage_list is None:
        print("No code coverage data found in the deployment result.")
        sys.exit(1 if has_failures else 0)

    if not coverage_list:
        print("Coverage list is empty — no Apex classes were covered.")
        sys.exit(1 if has_failures else 0)

    total_lines, covered_lines, failed_classes = report_per_class_coverage(coverage_list)
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

    if has_failures:
        sys.exit(1)

    print(f"\nCOVERAGE GATE PASSED: All classes meet the {COVERAGE_THRESHOLD}% minimum.")


if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else 'deploy-result.json'
    calculate_coverage(file_path)