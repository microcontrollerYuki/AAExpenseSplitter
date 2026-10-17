package com.aaexpense.transactionfixture;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONException;

import java.io.IOException;

/** A separate fixture app. It neither opens payment apps nor writes real bills. */
public final class MainActivity extends Activity {
    private ScenarioCatalog catalog;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle("AA 交易测试");
        try {
            catalog = ScenarioCatalog.load(getAssets());
            showRequestedScenario(getIntent());
        } catch (IOException | JSONException error) {
            final LinearLayout root = newRoot();
            root.addView(text("样例加载失败", 22));
            root.addView(text(error.getMessage(), 16));
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (catalog != null) {
            showRequestedScenario(intent);
        }
    }

    private void showRequestedScenario(Intent intent) {
        final String requested = intent == null ? null : intent.getStringExtra("scenario");
        if (requested == null) {
            showSelector(false);
            return;
        }
        final ScenarioCatalog.Scenario scenario = catalog.find(requested);
        if (scenario == null) {
            // Invalid launch input must not silently show a successful transaction.
            showSelector(true);
            return;
        }
        showScenario(scenario);
    }

    private void showSelector(boolean unknownScenario) {
        final LinearLayout root = newRoot();
        root.setId(R.id.fixture_selector);
        root.addView(text("AA 交易测试", 24));
        root.addView(text("仅供调试 · 全部交易信息为脱敏虚构样例", 15));
        root.addView(text("选择页面后，可比较画面与无障碍交易节点。", 15));
        if (unknownScenario) {
            root.addView(text("未知样例，请从列表选择。", 16));
        }
        final LinearLayout content = scrollingContent(root);
        for (ScenarioCatalog.Scenario scenario : catalog.cases) {
            final Button button = new Button(this);
            button.setText(scenario.title);
            button.setAllCaps(false);
            button.setOnClickListener(view -> showScenario(scenario));
            content.addView(button, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT));
        }
    }

    private void showScenario(ScenarioCatalog.Scenario scenario) {
        final LinearLayout root = newRoot();
        root.addView(text("AA 交易测试", 24));
        // Keep transaction status, amount and IDs out of the canvas page's controls.
        root.addView(text(scenario.mode.equals("nodes")
                ? "可读交易节点 · 脱敏样例" : "Canvas 画面 · 交易节点无文字", 15));
        final Button back = new Button(this);
        back.setText("返回样例");
        back.setOnClickListener(view -> showSelector(false));
        root.addView(back);

        final LinearLayout content = scrollingContent(root);
        content.setId(R.id.fixture_transaction);
        if (scenario.mode.equals("nodes")) {
            for (ScenarioCatalog.Line line : scenario.lines) {
                final TextView field = text(line.text, textSizeFor(line.id));
                field.setId(idForLine(line.id));
                if (line.id.equals("status") || line.id.equals("amount")) {
                    field.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
                }
                content.addView(field);
            }
        } else {
            final TransactionCanvasView canvas = new TransactionCanvasView(this, scenario);
            canvas.setId(R.id.fixture_canvas);
            content.addView(canvas, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT));
        }
    }

    private LinearLayout newRoot() {
        final LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);
        final int padding = dp(16);
        root.setPadding(padding, padding, padding, padding);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                final Insets bars = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                root.setPadding(padding + bars.left, padding + bars.top,
                        padding + bars.right, padding + bars.bottom);
            } else {
                root.setPadding(padding + insets.getSystemWindowInsetLeft(),
                        padding + insets.getSystemWindowInsetTop(),
                        padding + insets.getSystemWindowInsetRight(),
                        padding + insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        setContentView(root);
        root.requestApplyInsets();
        return root;
    }

    private LinearLayout scrollingContent(LinearLayout root) {
        final ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(false);
        root.addView(scroll, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        final LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        scroll.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT, ScrollView.LayoutParams.WRAP_CONTENT));
        return content;
    }

    private TextView text(String value, float sizeSp) {
        final TextView view = new TextView(this);
        view.setText(value);
        view.setTextColor(Color.rgb(25, 28, 32));
        view.setTextSize(sizeSp);
        view.setPadding(0, dp(6), 0, dp(6));
        return view;
    }

    static float textSizeFor(String lineId) {
        if (lineId.equals("status")) return 22;
        if (lineId.equals("amount")) return 25;
        return 16;
    }

    private int idForLine(String lineId) {
        switch (lineId) {
            case "status": return R.id.fixture_status;
            case "amount": return R.id.fixture_amount;
            case "subtotal": return R.id.fixture_subtotal;
            case "discount": return R.id.fixture_discount;
            case "balance": return R.id.fixture_balance;
            case "merchant": return R.id.fixture_merchant;
            case "payment_method": return R.id.fixture_payment_method;
            case "occurred_at": return R.id.fixture_occurred_at;
            case "transaction_id": return R.id.fixture_transaction_id;
            default: throw new IllegalArgumentException("Unknown transaction line ID");
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
