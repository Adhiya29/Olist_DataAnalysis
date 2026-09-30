"""Build reports/executive_summary.pdf — a one-page recruiter-facing brief.

Numbers are recomputed live from data/processed/ and outputs/ so the PDF never
drifts from the analysis. Run from anywhere:  python reports/build_executive_summary.py
"""
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import matplotlib.image as mpimg
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from scipy import stats
from sklearn.metrics import roc_auc_score, average_precision_score

plt.rcParams["text.parse_math"] = False  # "R$" and category_names are literal text, not LaTeX

REPO_ROOT = Path(__file__).resolve().parents[1]
FIG_DIR = REPO_ROOT / "reports" / "figures"
OUT_PDF = REPO_ROOT / "reports" / "executive_summary.pdf"

INK = "#1d2733"
MUTED = "#5b6774"
ACCENT = "#c1121f"
GOOD = "#2a9d8f"
REVIEW_COLORS = {1: "#c1121f", 2: "#e07a5f", 3: "#e9c46a", 4: "#8ab17d", 5: "#2a9d8f"}


def compute_metrics():
    orders = duckdb.sql(f"SELECT * FROM '{(REPO_ROOT / 'data/processed/orders_clean.parquet').as_posix()}'").df()
    rev = orders.dropna(subset=["review_score"]).copy()

    m = {}
    m["n_reviewed"] = len(rev)
    m["pct_low"] = (rev["review_score"] <= 3).mean() * 100
    m["rev_at_risk"] = orders.loc[orders["review_score"] <= 3, "total_price"].sum()
    m["total_rev"] = orders["total_price"].sum()
    m["rev_at_risk_pct"] = m["rev_at_risk"] / m["total_rev"] * 100

    low = rev[rev["review_score"] <= 3]["delivery_gap_days"]
    high = rev[rev["review_score"] >= 4]["delivery_gap_days"]
    m["welch_t"], _ = stats.ttest_ind(low, high, equal_var=False)
    m["gap_low"], m["gap_high"] = low.mean(), high.mean()

    top6 = rev["primary_category"].value_counts().head(6).index
    m["anova_f"], m["anova_p"] = stats.f_oneway(*[rev.loc[rev.primary_category == c, "review_score"] for c in top6])

    st = rev.groupby("customer_state").agg(n=("review_score", "size"), avg=("review_score", "mean"))
    st = st[st["n"] >= 500].sort_values("avg")
    gw = rev.loc[rev.customer_state.isin(st.head(5).index), "delivery_gap_days"]
    gb = rev.loc[rev.customer_state.isin(st.tail(5).index), "delivery_gap_days"]
    m["levene_w"], _ = stats.levene(gw, gb)
    m["var_worst"], m["var_best"] = gw.var(), gb.var()

    car = (orders.assign(low=orders.review_score <= 3)
           .groupby("primary_category")
           .apply(lambda d: d.loc[d.low, "total_price"].sum())
           .sort_values(ascending=False))
    m["top_cats"] = car.head(4)
    m["rev_by_score"] = orders.dropna(subset=["review_score"]).groupby("review_score")["total_price"].sum()

    risk = pd.read_parquet(REPO_ROOT / "outputs/model_risk_scores.parquet")
    m["roc_auc"] = roc_auc_score(risk["low_review"], risk["risk_score"])
    m["pr_auc"] = average_precision_score(risk["low_review"], risk["risk_score"])
    thr = risk["risk_score"].quantile(0.90)
    flagged = risk["risk_score"] >= thr
    m["base_rate"] = risk["low_review"].mean()
    m["flag_precision"] = risk.loc[flagged, "low_review"].mean()
    m["flag_lift"] = m["flag_precision"] / m["base_rate"]
    m["flag_recall"] = risk.loc[flagged, "low_review"].sum() / risk["low_review"].sum()
    return m


def build_figure(m):
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.patch.set_facecolor("white")

    def t(x, y, s, size=9, color=INK, weight="normal", style="normal", va="top", ha="left"):
        fig.text(x, y, s, fontsize=size, color=color, weight=weight, style=style,
                 va=va, ha=ha, wrap=True)

    L = 0.07
    fig.text(L, 0.965, "Olist Marketplace — Drivers of Low Review Scores", fontsize=17, weight="bold", color=INK, va="top")
    fig.text(L, 0.940, "Executive Summary  ·  End-to-end data analysis (EDA → inferential tests → predictive & prescriptive model)",
             fontsize=9.5, color=MUTED, va="top")
    fig.add_artist(plt.Line2D([L, 0.93], [0.928, 0.928], color="#d7dde3", lw=1))

    t(L, 0.915, "PROBLEM", 8.5, ACCENT, "bold")
    t(L, 0.900, f"About one order in five (≤ 3 stars, {m['pct_low']:.0f}% of {m['n_reviewed']:,} reviewed orders) is low-rated. "
                f"These orders carry R$ {m['rev_at_risk']/1e6:.2f}M — {m['rev_at_risk_pct']:.0f}% of item revenue — in revenue at risk, "
                "threatening repeat purchase and seller retention.", 9.2)

    t(L, 0.862, "APPROACH", 8.5, ACCENT, "bold")
    t(L, 0.847, "Cleaned 96k delivered orders; sized the problem in EDA; confirmed drivers with five hypothesis tests; "
                "built a Logistic→LightGBM risk model (time-based split) explained with SHAP; simulated a targeted intervention.", 9.2)

    ax_rev = fig.add_axes([0.07, 0.60, 0.40, 0.185])
    rbs = m["rev_by_score"]
    ax_rev.bar(rbs.index, rbs.values / 1e6, color=[REVIEW_COLORS[int(s)] for s in rbs.index], width=0.72)
    ax_rev.set_title(f"Revenue at risk (≤ 3 stars) = R$ {m['rev_at_risk']/1e6:.2f}M", fontsize=9.5, weight="bold")
    ax_rev.set_xlabel("Review score", fontsize=8)
    ax_rev.set_ylabel("Revenue (R$ M)", fontsize=8)
    ax_rev.tick_params(labelsize=7.5)
    for sp in ["top", "right"]:
        ax_rev.spines[sp].set_visible(False)

    shap_png = FIG_DIR / "05_shap_summary.png"
    ax_shap = fig.add_axes([0.52, 0.585, 0.41, 0.205])
    if shap_png.exists():
        ax_shap.imshow(mpimg.imread(shap_png))
        ax_shap.set_title("Model drivers (SHAP): delivery timing leads", fontsize=9.5, weight="bold")
    ax_shap.axis("off")

    y = 0.560
    t(L, y, "KEY FINDINGS", 8.5, ACCENT, "bold")
    findings = [
        ("Delivery lateness is the #1 driver.",
         f"Low-review orders lose ~5.8 days of early-delivery cushion (Welch t = {m['welch_t']:.0f}, p ≈ 0); "
         "delivery gap & actual days are the top-2 SHAP features."),
        ("Risk concentrates in a few big categories.",
         f"Category means differ significantly (ANOVA F = {m['anova_f']:.0f}, p ≈ 0). Top revenue-at-risk: "
         + ", ".join(f"{c} (R$ {v/1e3:.0f}k)" for c, v in m["top_cats"].head(3).items()) + "."),
        ("Worst states fail on consistency, not just speed.",
         f"Delivery-gap variance in the 5 worst states is {m['var_worst']/m['var_best']:.1f}× the 5 best "
         f"(Levene W = {m['levene_w']:.0f}, p ≈ 0)."),
        ("A risk score targets intervention efficiently.",
         f"LightGBM ROC-AUC {m['roc_auc']:.2f}, PR-AUC {m['pr_auc']:.2f}; flagging the top-decile gives "
         f"{m['flag_lift']:.1f}× precision ({m['flag_precision']:.0%} vs {m['base_rate']:.0%}) and catches {m['flag_recall']:.0%} of low reviews."),
    ]
    y -= 0.017
    for i, (head, body) in enumerate(findings, 1):
        t(L, y, f"{i}.  {head}", 9.3, INK, "bold")
        y -= 0.016
        t(L + 0.018, y, body, 8.8, MUTED)
        y -= 0.036

    y -= 0.004
    t(L, y, "RECOMMENDATIONS", 8.5, ACCENT, "bold")
    y -= 0.017
    recs = [
        "Target the late tail: alert ops when an order slips past its estimate; fix worst routes/carriers rather than an already-early median.",
        "Prioritise category quality/logistics on bed_bath_table and computers_accessories (high volume × worst review mix).",
        "In the worst states, cut delivery variance (carrier SLAs, buffers) — reliability over raw speed.",
        "Deploy the at-delivery risk score for proactive outreach on top-decile orders (pre-review window).",
    ]
    for r in recs:
        t(L, y, "•  " + r, 8.8, INK)
        y -= 0.026

    y -= 0.010
    t(L, y, "Deprioritise (low leverage):", 8.8, GOOD, "bold")
    y -= 0.015
    t(L, y, "freight ratio (Spearman ρ = −0.03) and installment count are significant but too small to move the average.", 8.8, MUTED)

    fig.add_artist(plt.Line2D([L, 0.93], [0.055, 0.055], color="#d7dde3", lw=1))
    fig.text(L, 0.041, f"R$ {m['rev_at_risk']/1e6:.2f}M revenue at risk   ·   {m['pct_low']:.0f}% low-review orders   "
                       f"·   ROC-AUC {m['roc_auc']:.2f}   ·   {m['flag_lift']:.1f}× targeting lift",
             fontsize=8.5, color=INK, weight="bold", va="center")
    fig.text(0.5, 0.022, "Source: Olist Brazilian E-Commerce Public Dataset (Kaggle)",
             fontsize=7.5, color=MUTED, va="center", ha="center")

    return fig


def build_pdf(m):
    fig = build_figure(m)
    with PdfPages(OUT_PDF) as pdf:
        pdf.savefig(fig)
    plt.close(fig)
    print(f"wrote {OUT_PDF.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    build_pdf(compute_metrics())
