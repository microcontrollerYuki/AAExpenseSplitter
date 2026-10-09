package com.aaexpense.transactionfixture;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.util.TypedValue;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

/** Visible transaction text, intentionally without accessible transaction text nodes. */
final class TransactionCanvasView extends View {
    private final ScenarioCatalog.Scenario scenario;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

    TransactionCanvasView(Context context, ScenarioCatalog.Scenario scenario) {
        super(context);
        this.scenario = scenario;
        setBackgroundColor(Color.WHITE);
        setFocusable(false);
        setClickable(false);
        // This is a test fixture for a page that omits transaction semantics.
        // The text is drawn, never placed in text/contentDescription/virtual nodes.
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        final int width = resolveSize(dp(360), widthMeasureSpec);
        final int available = Math.max(1, width - dp(16));
        float height = dp(16);
        for (ScenarioCatalog.Line line : scenario.lines) {
            configurePaint(line.id);
            final Paint.FontMetrics metrics = paint.getFontMetrics();
            height += wrapText(line.text, available).size()
                    * (metrics.bottom - metrics.top) + dp(12);
        }
        setMeasuredDimension(width, resolveSize((int) Math.ceil(height), heightMeasureSpec));
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        final int available = Math.max(1, getWidth() - dp(16));
        float top = dp(8);
        for (ScenarioCatalog.Line line : scenario.lines) {
            configurePaint(line.id);
            final Paint.FontMetrics metrics = paint.getFontMetrics();
            for (String part : wrapText(line.text, available)) {
                canvas.drawText(part, dp(8), top - metrics.top, paint);
                top += metrics.bottom - metrics.top;
            }
            top += dp(12);
        }
    }

    private void configurePaint(String lineId) {
        paint.setColor(Color.rgb(25, 28, 32));
        paint.setTextSize(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP,
                MainActivity.textSizeFor(lineId), getResources().getDisplayMetrics()));
        paint.setTypeface(lineId.equals("status") || lineId.equals("amount")
                ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
    }

    private List<String> wrapText(String value, int availableWidth) {
        final List<String> result = new ArrayList<>();
        int offset = 0;
        while (offset < value.length()) {
            final int count = Math.max(1, paint.breakText(
                    value, offset, value.length(), true, availableWidth, null));
            result.add(value.substring(offset, offset + count));
            offset += count;
        }
        return result;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
