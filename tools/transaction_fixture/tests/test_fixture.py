"""Static contract checks for the standalone, debug-only transaction fixture.

Run with Python's standard-library unittest discovery. These tests read files only;
they do not invoke Gradle, install an APK, contact a device, or inspect private data.
"""

import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


FIXTURE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = FIXTURE_ROOT.parents[1]
MODULE_ROOT = FIXTURE_ROOT / "fixtureApp"
DEBUG_ROOT = MODULE_ROOT / "src" / "debug"
PACKAGE_NAME = "com.aaexpense.transactionfixture"
JAVA_ROOT = DEBUG_ROOT / "java" / Path(*PACKAGE_NAME.split("."))
ANDROID = "{http://schemas.android.com/apk/res/android}"

CASE_MATRIX = {
    "nodes_success": ("nodes", "success", 1234, 1234),
    "nodes_failed": ("nodes", "failed", 1234, None),
    "nodes_multi": ("nodes", "success", 9000, 9000),
    "canvas_success": ("canvas", "success", 1234, 1234),
    "canvas_failed": ("canvas", "failed", 1234, None),
    "canvas_multi": ("canvas", "success", 9000, 9000),
}
CASE_FIELDS = {
    "id", "mode", "title", "status", "direction", "currency", "amountCents",
    "expectedRecordedCents", "merchant", "transactionId", "occurredAt",
    "paymentMethod", "lines",
}


def read_text(path):
    return path.read_text(encoding="utf-8-sig")


def has_amount(text, amount):
    return re.search(r"(?<![\d.,])" + re.escape(amount) + r"(?![\d.,])", text) is not None


def without_comments(source):
    """Remove Java/Groovy comments while preserving quoted string contents."""
    token = re.compile(
        r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*.*?\*/',
        re.DOTALL,
    )
    return token.sub(
        lambda match: " " if match.group().startswith(("//", "/*")) else match.group(),
        source,
    )


def braced_block(source, declaration):
    """Return a declared block, ignoring braces inside Java/Groovy strings."""
    match = re.search(declaration, source, re.DOTALL)
    if not match:
        raise AssertionError("Required declaration was not found: " + declaration)
    opening = source.find("{", match.end())
    if opening < 0:
        raise AssertionError("Declaration has no body: " + declaration)
    masked = re.sub(
        r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        lambda token: " " * len(token.group()),
        source,
        flags=re.DOTALL,
    )
    depth = 0
    for offset in range(opening, len(source)):
        if masked[offset] == "{":
            depth += 1
        elif masked[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:offset]
    raise AssertionError("Declaration has an unclosed body: " + declaration)


class ScenarioContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(read_text(DEBUG_ROOT / "assets" / "scenarios.json"))
        cls.cases = cls.catalog["cases"]

    def test_version_and_exact_six_case_matrix(self):
        self.assertEqual(1, self.catalog["schemaVersion"])
        self.assertIs(type(self.catalog["schemaVersion"]), int)
        self.assertIsInstance(self.cases, list)
        self.assertEqual(6, len(self.cases))
        self.assertEqual(set(CASE_MATRIX), {case["id"] for case in self.cases})
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertTrue(CASE_FIELDS.issubset(case))
                mode, status, amount, recorded = CASE_MATRIX[case["id"]]
                self.assertEqual(mode, case["mode"])
                self.assertEqual(status, case["status"])
                self.assertEqual(amount, case["amountCents"])
                self.assertEqual(recorded, case["expectedRecordedCents"])

    def test_transaction_metadata_is_explicit_and_typed(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertEqual("expense", case["direction"])
                self.assertEqual("CNY", case["currency"])
                self.assertIs(type(case["amountCents"]), int)
                self.assertGreater(case["amountCents"], 0)
                recorded = case["expectedRecordedCents"]
                if recorded is not None:
                    self.assertIs(type(recorded), int)
                    self.assertEqual(case["amountCents"], recorded)
                for field in ("title", "merchant", "transactionId", "occurredAt", "paymentMethod"):
                    self.assertIsInstance(case[field], str)
                    self.assertTrue(case[field].strip(), field)

    def test_transaction_ids_are_unique_across_all_renderers(self):
        transaction_ids = [case["transactionId"] for case in self.cases]
        self.assertEqual(len(transaction_ids), len(set(transaction_ids)))

    def test_every_display_line_has_nonempty_text_and_unique_identity(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertIsInstance(case["lines"], list)
                self.assertTrue(case["lines"])
                line_ids = []
                for line in case["lines"]:
                    self.assertTrue({"id", "text"}.issubset(line))
                    for field in ("id", "text"):
                        self.assertIsInstance(line[field], str)
                        self.assertTrue(line[field].strip(), field)
                    line_ids.append(line["id"])
                self.assertEqual(len(line_ids), len(set(line_ids)))

    def test_displayed_amount_does_not_make_failed_cases_recordable(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                displayed_amount = "90.00" if case["id"].endswith("_multi") else "12.34"
                self.assertTrue(any(has_amount(line["text"], displayed_amount) for line in case["lines"]))
                if case["status"] == "failed":
                    self.assertIsNone(case["expectedRecordedCents"])
                    self.assertTrue(any("失败" in line["text"] for line in case["lines"]))
                else:
                    self.assertEqual(case["amountCents"], case["expectedRecordedCents"])

    def test_multiple_amount_cases_keep_the_paid_amount_and_distractors(self):
        for case in self.cases:
            if not case["id"].endswith("_multi"):
                continue
            with self.subTest(case=case["id"]):
                for label, amount in (
                    ("原价", "100.00"), ("优惠", "10.00"),
                    ("实付", "90.00"), ("余额", "1,234.56"),
                ):
                    self.assertTrue(
                        any(label in line["text"] and has_amount(line["text"], amount) for line in case["lines"]),
                        "Missing displayed amount: " + label + " " + amount,
                    )
                self.assertEqual(9000, case["amountCents"])
                self.assertEqual(9000, case["expectedRecordedCents"])

    def test_paired_renderers_share_business_data(self):
        by_id = {case["id"]: case for case in self.cases}

        def normalized(case):
            values = {
                key: value for key, value in case.items()
                if key not in {"id", "mode", "title", "transactionId", "lines"}
            }
            values["lines"] = [
                dict(line, text=line["text"].replace(case["transactionId"], "<transaction-id>"))
                for line in case["lines"]
            ]
            return values

        for kind in ("success", "failed", "multi"):
            with self.subTest(kind=kind):
                self.assertEqual(
                    normalized(by_id["nodes_" + kind]),
                    normalized(by_id["canvas_" + kind]),
                )


class ProjectIsolationTests(unittest.TestCase):
    def test_project_has_its_own_only_application_module(self):
        settings = without_comments(read_text(FIXTURE_ROOT / "settings.gradle"))
        includes = re.findall(r'\binclude\s*\(?\s*["\'](:[^"\']+)["\']', settings)
        self.assertEqual([":fixtureApp"], includes)
        self.assertNotRegex(settings, r"\bincludeBuild\s*\(")
        scripts = [FIXTURE_ROOT / "build.gradle", MODULE_ROOT / "build.gradle"]
        combined = "\n".join(without_comments(read_text(path)) for path in scripts)
        plugins = re.findall(r'\bid\s*\(?\s*["\']([^"\']+)["\']', combined)
        self.assertEqual({"com.android.application"}, set(plugins))
        self.assertRegex(combined, r'com\.android\.application["\']\s*\)?\s*version\s*["\']9\.1\.0["\']')
        self.assertNotIn("flutter", combined.lower())

    def test_package_sdk_and_java_are_standalone(self):
        gradle = without_comments(read_text(MODULE_ROOT / "build.gradle"))
        for key in ("namespace", "applicationId"):
            self.assertRegex(gradle, key + r'\s*(?:=\s*)?["\']' + re.escape(PACKAGE_NAME) + r'["\']')
        for key, value in (("compileSdk", 36), ("targetSdk", 36), ("minSdk", 24)):
            self.assertRegex(gradle, key + r"\s*(?:=\s*)?" + str(value) + r"\b")
        for key in ("sourceCompatibility", "targetCompatibility"):
            self.assertRegex(gradle, key + r"\s*(?:=\s*)?JavaVersion\.VERSION_17\b")
        properties = {
            line.split("=", 1)[0].strip(): line.split("=", 1)[1].strip()
            for line in read_text(FIXTURE_ROOT / "gradle.properties").splitlines()
            if "=" in line and not line.lstrip().startswith(("#", "!"))
        }
        self.assertEqual("false", properties.get("android.builtInKotlin"))

    def test_release_variant_is_disabled_before_creation(self):
        gradle = without_comments(read_text(MODULE_ROOT / "build.gradle"))
        components = braced_block(gradle, r"\bandroidComponents\b")
        release = braced_block(
            components,
            r'\bbeforeVariants\s*\(\s*selector\s*\(\s*\)\s*\.withBuildType\s*\(\s*["\']release["\']\s*\)\s*\)',
        )
        parameter = re.search(r"\b(\w+)\s*->", release)
        self.assertIsNotNone(parameter)
        self.assertRegex(release, r"\b" + re.escape(parameter.group(1)) + r"\.enable\s*=\s*false\b")
        self.assertNotRegex(release, r"\.enable\s*=\s*true\b")

    def test_fixture_has_no_runtime_dependencies_or_production_source_links(self):
        for path in FIXTURE_ROOT.rglob("*.gradle"):
            if not path.is_file():
                continue
            with self.subTest(path=path.relative_to(FIXTURE_ROOT)):
                source = without_comments(read_text(path))
                self.assertNotRegex(
                    source,
                    r"\b(?:implementation|api|runtimeOnly|debugImplementation|releaseImplementation|debugRuntimeOnly|releaseRuntimeOnly)\b",
                )
                self.assertNotRegex(source, r"(?i)(?:aa_expense_splitter|app[/\\]+android|flutter)")
                self.assertNotRegex(source, r"\.\.[/\\]")
        libs = MODULE_ROOT / "libs"
        self.assertFalse(libs.exists() and any(path.is_file() for path in libs.rglob("*")))
        production = REPOSITORY_ROOT / "app" / "android"
        for path in production.rglob("*.gradle.kts"):
            if not path.is_file():
                continue
            source = read_text(path)
            self.assertNotIn("transaction_fixture", source)
            self.assertNotIn(PACKAGE_NAME, source)

    def test_main_source_set_is_only_a_minimal_manifest(self):
        main_root = MODULE_ROOT / "src" / "main"
        self.assertEqual(
            [Path("AndroidManifest.xml")],
            sorted(path.relative_to(main_root) for path in main_root.rglob("*") if path.is_file()),
        )
        main_manifest = ET.parse(main_root / "AndroidManifest.xml").getroot()
        self.assertEqual("manifest", main_manifest.tag)
        self.assertEqual(0, len(main_manifest))

    def test_debug_manifest_is_test_only_and_does_not_allow_backups(self):
        manifest = ET.parse(DEBUG_ROOT / "AndroidManifest.xml").getroot()
        application = manifest.find("application")
        self.assertIsNotNone(application)
        self.assertEqual("true", application.get(ANDROID + "testOnly"))
        self.assertEqual("false", application.get(ANDROID + "allowBackup"))
        self.assertEqual([], manifest.findall("uses-permission"))
        self.assertEqual([], application.findall("service"))
        self.assertEqual([], application.findall("receiver"))
        self.assertEqual([], application.findall("provider"))
        activities = application.findall("activity")
        self.assertEqual(1, len(activities))
        activity = activities[0]
        self.assertIn(activity.get(ANDROID + "name"), (".MainActivity", PACKAGE_NAME + ".MainActivity"))
        self.assertEqual("true", activity.get(ANDROID + "exported"))
        filters = activity.findall("intent-filter")
        self.assertTrue(any(
            any(action.get(ANDROID + "name") == "android.intent.action.MAIN" for action in entry.findall("action"))
            and any(category.get(ANDROID + "name") == "android.intent.category.LAUNCHER" for category in entry.findall("category"))
            for entry in filters
        ))


class SharedRendererSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.activity = without_comments(read_text(JAVA_ROOT / "MainActivity.java"))
        cls.catalog = without_comments(read_text(JAVA_ROOT / "ScenarioCatalog.java"))
        cls.canvas = without_comments(read_text(JAVA_ROOT / "TransactionCanvasView.java"))

    def test_java_sources_belong_only_to_the_debug_fixture_package(self):
        sources = list((MODULE_ROOT / "src").rglob("*.java"))
        self.assertTrue(sources)
        for path in sources:
            with self.subTest(path=path.relative_to(MODULE_ROOT)):
                self.assertIn(JAVA_ROOT, path.parents)
                self.assertRegex(without_comments(read_text(path)), r"\bpackage\s+" + re.escape(PACKAGE_NAME) + r"\s*;")

    def test_catalog_is_the_shared_asset_model(self):
        self.assertEqual(
            [DEBUG_ROOT / "assets" / "scenarios.json"],
            list((MODULE_ROOT / "src").rglob("scenarios.json")),
        )
        self.assertIn('"scenarios.json"', self.catalog)
        self.assertRegex(self.catalog, r"\bload\s*\(\s*AssetManager\s+\w+\s*\)")
        self.assertRegex(self.catalog, r"\bclass\s+Scenario\b")
        self.assertRegex(self.catalog, r"\bclass\s+Line\b")
        self.assertRegex(self.catalog, r"List\s*<\s*Line\s*>\s+lines\b")
        self.assertRegex(self.activity, r"ScenarioCatalog\s*\.\s*load\s*\(\s*getAssets\s*\(\s*\)\s*\)")
        self.assertNotIn('"scenarios.json"', self.activity)
        self.assertNotIn('"scenarios.json"', self.canvas)

    def test_both_renderers_receive_the_same_selected_scenario(self):
        body = braced_block(self.activity, r"\bshowScenario\s*\(\s*ScenarioCatalog\.Scenario\s+scenario\s*\)")
        self.assertRegex(body, r"new\s+TransactionCanvasView\s*\(\s*this\s*,\s*scenario\s*\)")
        self.assertRegex(body, r"\bscenario\s*\.\s*lines\b")
        self.assertRegex(body, r"\bTextView\b")
        self.assertRegex(body, r"\btext\s*\(\s*\w+\.text\s*,")
        text_helper = braced_block(self.activity, r"\btext\s*\(\s*String\s+value\s*,\s*float\s+\w+\s*\)")
        self.assertRegex(text_helper, r"\.\s*setText\s*\(\s*value\s*\)")
        self.assertRegex(self.canvas, r"\bScenarioCatalog\.Scenario\s+scenario\b")
        self.assertRegex(self.canvas, r"\bthis\.scenario\s*=\s*scenario\s*;")

    def test_every_asset_line_has_a_distinct_declared_readable_node_id(self):
        catalog = json.loads(read_text(DEBUG_ROOT / "assets" / "scenarios.json"))
        expected = {line["id"] for case in catalog["cases"] for line in case["lines"]}
        mapper = braced_block(self.activity, r"\bidForLine\s*\(\s*String\s+\w+\s*\)")
        pairs = re.findall(r'\bcase\s+"([^"]+)"\s*:\s*return\s+R\.id\.(\w+)\s*;', mapper)
        mapping = dict(pairs)
        self.assertEqual(expected, set(mapping))
        self.assertEqual(len(pairs), len(mapping))
        self.assertEqual(len(mapping), len(set(mapping.values())))
        resources = ET.parse(DEBUG_ROOT / "res" / "values" / "ids.xml").getroot()
        declared = {item.get("name") for item in resources.findall("item") if item.get("type") == "id"}
        self.assertTrue(set(mapping.values()).issubset(declared))
        body = braced_block(self.activity, r"\bshowScenario\s*\(\s*ScenarioCatalog\.Scenario\s+scenario\s*\)")
        self.assertRegex(body, r"\.setId\s*\(\s*idForLine\s*\(\s*\w+\.id\s*\)\s*\)")

    def test_canvas_controls_remain_nodes_without_exposing_transaction_values(self):
        body = braced_block(self.activity, r"\bshowScenario\s*\(\s*ScenarioCatalog\.Scenario\s+scenario\s*\)")
        branch = re.search(r'\bif\s*\(\s*scenario\.mode\.equals\("nodes"\)\s*\)', body)
        self.assertIsNotNone(branch)
        controls = body[:branch.start()]
        self.assertRegex(controls, r"new\s+Button\s*\(\s*this\s*\)")
        self.assertRegex(controls, r'\.setText\s*\(\s*"返回样例"\s*\)')
        self.assertRegex(controls, r"\.setOnClickListener\s*\(")
        self.assertNotRegex(controls, r"scenario\.(?:title|lines|status|amountCents|merchant|transactionId|occurredAt|paymentMethod)\b")
        self.assertNotIn("IMPORTANT_FOR_ACCESSIBILITY_NO", self.activity)

    def test_canvas_draws_scenario_lines_without_accessibility_transaction_nodes(self):
        on_draw = braced_block(self.canvas, r"\bonDraw\s*\(\s*Canvas\s+\w+\s*\)")
        self.assertRegex(on_draw, r"\bscenario\s*\.\s*lines\b")
        self.assertRegex(on_draw, r"\b\w+\.text\b")
        self.assertRegex(on_draw, r"\bdrawText\s*\(")
        self.assertNotRegex(on_draw, r'\bdrawText\s*\(\s*["\']')
        self.assertRegex(self.canvas, r"setImportantForAccessibility\s*\(\s*View\.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS\s*\)")
        self.assertNotRegex(
            self.canvas,
            r"\b(?:setText|setContentDescription|onInitializeAccessibilityNodeInfo|"
            r"getAccessibilityNodeProvider|AccessibilityNodeProvider|AccessibilityNodeInfo|"
            r"ExploreByTouchHelper|onPopulateAccessibilityEvent|dispatchPopulateAccessibilityEvent|"
            r"addExtraDataToAccessibilityNodeInfo|createAccessibilityNodeInfo)\b",
        )
        for source in (self.activity, self.canvas):
            for amount in ("12.34", "100.00", "10.00", "90.00", "1,234.56"):
                self.assertNotIn(amount, source, "Transaction amounts must come from scenarios.json")


if __name__ == "__main__":
    unittest.main()
