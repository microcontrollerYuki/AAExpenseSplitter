package com.aaexpense.transactionfixture;

import android.content.res.AssetManager;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** One immutable, synthetic data source for both transaction renderers. */
final class ScenarioCatalog {
    final List<Scenario> cases;

    private ScenarioCatalog(List<Scenario> cases) {
        this.cases = Collections.unmodifiableList(cases);
    }

    static ScenarioCatalog load(AssetManager assets) throws IOException, JSONException {
        final String json;
        try (InputStream input = assets.open("scenarios.json");
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            final byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            json = new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
        final JSONObject root = new JSONObject(json);
        if (root.getInt("schemaVersion") != 1) {
            throw new JSONException("Unsupported scenario schema");
        }
        final JSONArray rows = root.getJSONArray("cases");
        final List<Scenario> cases = new ArrayList<>();
        final Set<String> ids = new HashSet<>();
        for (int index = 0; index < rows.length(); index++) {
            final JSONObject row = rows.getJSONObject(index);
            final String id = row.getString("id");
            if (id.isEmpty() || !ids.add(id)) {
                throw new JSONException("Empty or duplicate scenario ID");
            }
            final String mode = row.getString("mode");
            if (!mode.equals("nodes") && !mode.equals("canvas")) {
                throw new JSONException("Unsupported scenario mode");
            }
            final List<Line> lines = new ArrayList<>();
            final Set<String> lineIds = new HashSet<>();
            final JSONArray lineRows = row.getJSONArray("lines");
            for (int lineIndex = 0; lineIndex < lineRows.length(); lineIndex++) {
                final JSONObject line = lineRows.getJSONObject(lineIndex);
                final String lineId = line.getString("id");
                final String text = line.getString("text");
                if (lineId.isEmpty() || text.isEmpty() || !lineIds.add(lineId)) {
                    throw new JSONException("Empty or duplicate transaction line");
                }
                lines.add(new Line(lineId, text));
            }
            if (lines.isEmpty()) {
                throw new JSONException("Scenario has no transaction lines");
            }
            cases.add(new Scenario(id, mode, row.getString("title"), lines));
        }
        if (cases.isEmpty()) {
            throw new JSONException("No transaction scenarios");
        }
        return new ScenarioCatalog(cases);
    }

    Scenario find(String id) {
        for (Scenario scenario : cases) {
            if (scenario.id.equals(id)) {
                return scenario;
            }
        }
        return null;
    }

    static final class Scenario {
        final String id;
        final String mode;
        final String title;
        final List<Line> lines;

        Scenario(String id, String mode, String title, List<Line> lines) {
            this.id = id;
            this.mode = mode;
            this.title = title;
            this.lines = Collections.unmodifiableList(lines);
        }
    }

    static final class Line {
        final String id;
        final String text;

        Line(String id, String text) {
            this.id = id;
            this.text = text;
        }
    }
}
