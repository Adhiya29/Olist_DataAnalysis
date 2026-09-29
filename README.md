# Olist Marketplace — Drivers of Low Review Scores

**A resume-worthy end-to-end data analysis project for a Data Analyst role (targeting ~3 years experience level).**

> This README is the working brief for Claude Code. Follow the phases in order. Each phase has its own notebook. Do not skip cleaning or jump straight to modeling. Ask before making a judgment call that changes the business framing (e.g. dropping a large chunk of data, changing the target definition).

---

## 1. Business Problem

Olist is a Brazilian e-commerce marketplace connecting small sellers to major retail platforms. Revenue depends on GMV and seller retention, both of which depend on customer satisfaction — measured through post-delivery review scores (1–5 stars). A meaningful share of orders receive review scores of 3 or below.

**Primary business question:**
> What are the top drivers of low review scores (≤ 3) on Olist, and which interventions would produce the largest lift in average review score?

**Sub-questions, mapped to the phase that answers them:**

| # | Sub-question | Phase |
|---|---|---|
| 1 | How large is the problem, and what's the revenue at risk? | EDA |
| 2 | Is late delivery the main culprit? | SQL + Inferential (t-test) |
| 3 | Do review scores differ meaningfully across product categories? | Inferential (ANOVA + Tukey HSD) |
| 4 | Are some states structurally worse (mean *and* variance)? | Inferential (Levene's test) |
| 5 | Does payment behavior (installments) relate to dissatisfaction? | Inferential (chi-square) |
| 6 | Can we predict a low-review order before it's delivered? | Predictive (Logistic Regression → LightGBM) |
| 7 | Which orders should ops proactively intervene on? | Prescriptive (risk threshold + estimated impact) |

Every phase must tie back to one of these questions. No chart, table, or test should exist "just because."

---

## 2. Dataset

**Source:** Brazilian E-Commerce Public Dataset by Olist (Kaggle) — https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

**Location in this repo:** raw CSVs are placed directly in `data/raw/` by the user before Claude Code starts work. Expected files:

```
data/raw/
├── olist_orders_dataset.csv
├── olist_order_items_dataset.csv
├── olist_order_reviews_dataset.csv
├── olist_order_payments_dataset.csv
├── olist_customers_dataset.csv
├── olist_sellers_dataset.csv
├── olist_products_dataset.csv
├── olist_geolocation_dataset.csv        (optional — only needed for state-level mapping)
└── product_category_name_translation.csv
```

Claude Code should verify all expected files are present at the start of Phase 1 and stop to ask if any are missing, rather than guessing or proceeding with partial data.

**Grain of each table** (document this explicitly in the Phase 1 notebook before writing any joins):
- `orders`: one row per order
- `order_items`: one row per item within an order (an order can have multiple items/sellers)
- `order_reviews`: one row per review (occasionally more than one per order — dedupe logic needed)
- `order_payments`: one row per payment method used per order (an order can have multiple installment rows)
- `customers`: one row per customer (note: `customer_id` is order-specific; `customer_unique_id` identifies the actual person across orders)
- `sellers`: one row per seller
- `products`: one row per product

---

## 3. Repository Structure

Claude Code should create and maintain this structure:

```
Olist_DataAnalysis/
├── README.md                        ← this file
├── requirements.txt
├── .gitignore                       ← exclude data/*.csv (large files, not committed)
├── data/
│   ├── raw/                         ← user-provided CSVs (already present, do not modify)
│   └── processed/                   ← cleaned parquet files (Phase 1 output)
├── notebooks/
│   ├── 01_cleaning.ipynb
│   ├── 02_sql_analysis.ipynb
│   ├── 03_eda.ipynb
│   ├── 04_statistical_analysis.ipynb
│   └── 05_modeling.ipynb
├── sql/
│   └── queries.sql                  ← standalone, commented SQL (recruiter-readable without opening a notebook)
├── src/
│   ├── data_loader.py
│   ├── cleaning.py
│   └── features.py
├── reports/
│   ├── executive_summary.pdf        ← 1-page, Phase 6 output
│   └── figures/                     ← key charts saved as PNG, reused later in Power BI
└── outputs/
    └── model_risk_scores.parquet    ← order-level predicted probabilities, for Phase 6 prescriptive analysis
```

`requirements.txt` should include at minimum: `pandas`, `duckdb`, `numpy`, `scipy`, `statsmodels`, `scikit-learn`, `lightgbm`, `shap`, `matplotlib`, `seaborn`, `pyarrow`.

---

## 4. Phase 1 — Data Loading & Schema Mapping

**Notebook:** `01_cleaning.ipynb` (schema mapping section, before cleaning)

- Load all CSVs into pandas, confirm row counts and column dtypes.
- Produce a short Mermaid ER diagram (markdown cell) showing how the 8–9 tables join, with the join keys labeled.
- Write one paragraph per table stating its grain (see Section 2) and any gotcha (e.g., `customer_id` vs `customer_unique_id`).

## 5. Phase 1 — Data Cleaning

**Notebook:** `01_cleaning.ipynb`

Every cleaning decision must be justified in a markdown cell above the code — not just performed silently.

- Filter to `order_status == 'delivered'` only. State why: reviews on undelivered/canceled orders aren't measuring the thing we care about.
- Parse and standardize all timestamp columns; compute `delivery_gap_days = actual_delivery_date - estimated_delivery_date` (positive = late).
- Join `product_category_name_translation` to get English category names; keep the Portuguese name as a fallback for unmapped categories.
- Aggregate `order_items` to order level: `total_price`, `total_freight`, `item_count`, `distinct_seller_count`.
- Aggregate `order_payments` to order level: `total_payment_value`, `max_installments`, `payment_type` (mode or primary method if multiple).
- Deduplicate `order_reviews` — some orders have more than one review row; keep the most recent by `review_answer_timestamp`, document how many rows this affected.
- Outlier treatment on `price` and `freight_value`: use IQR as a starting flag, but manually sanity-check flagged extremes before dropping anything (e.g., a high freight value for a heavy appliance is legitimate, not an error). Log what was dropped and why.
- Save the cleaned, order-grain table to `data/processed/orders_clean.parquet`.

## 6. Phase 2 — SQL Analysis (DuckDB)

**Notebook:** `02_sql_analysis.ipynb`
**Also export to:** `sql/queries.sql` (commented, standalone — this file should be readable and runnable independent of the notebook)

Use DuckDB directly on the cleaned tables from Phase 1. Every query must have a comment block above it stating (a) the business question it answers, (b) the grain of the result, and (c) how to read the output. Every result should be a business signal, not a stat for its own sake — if the direction of the answer is guessable without running the query, the query does not belong here.

### Cross-cutting rule: control for category and product type

Comparing dissimilar products directly (e.g., furniture delivery time vs. cosmetics delivery time) will produce misleading averages — a 10-day delivery is normal for a wardrobe and a disaster for a lipstick. Any query pooling across categories risks Simpson's paradox: the pooled result contradicting what's true within each segment. Every query below either partitions by category, controls for category, or explicitly reports why pooling is acceptable in that specific case. Claude Code must maintain this discipline throughout — including in any exploratory queries not listed here.

### Table grain reminder

- Order-level queries (Q0, Q1, Q2, Q3, Q7, Q8) → run against `orders_clean.parquet`.
- Seller-level queries (Q4, Q6) → run against `order_items` joined to `sellers`, `orders`, `order_reviews`, and `products` — **not** against `orders_clean`, which is order-grain and does not carry a single `seller_id` per row.
- Confirm the grain of the result table for each query in a print statement before displaying results.

### Queries

**Q0 — Baseline snapshot**
- **Question:** How large is the low-review problem, and what has the monthly trend looked like?
- **Output:** Two result sets in one query (via CTEs): (a) overall — total orders, total revenue, avg review score, % of orders with review ≤ 3; (b) monthly — order volume, avg review score, and % low-review by month.
- **Techniques:** CTE.

**Q1 — Category priority matrix**
- **Question:** Which product categories should be prioritized for intervention? Prioritization must weight both size and severity — a small underperforming category is not the same problem as a huge one.
- **Output:** One row per product category with volume, revenue, avg review score, % low-review, and **revenue-at-risk = SUM(total_price) WHERE review_score ≤ 3** — the actual dollars tied to that category's bad-review orders, rather than an estimate that assumes bad-review orders are priced like the category average (which would hide the difference between expensive products failing vs. cheap ones failing). Ranked by revenue-at-risk descending. Also add a rank column using `RANK() OVER (ORDER BY revenue_at_risk DESC)`.
- **Techniques:** CTE + window function (RANK).

**Q2 — Delivery-sensitivity by category**
- **Question:** Does late delivery hurt reviews equally across categories, or are some categories much more delivery-sensitive than others?
- **Output:** For each category, avg review score at each delivery-gap bucket. Buckets: `baseline` (`delivery_gap_days <= 0`, i.e. arrived on time or early — merged into one bucket because the exact on-time day alone is too thin to trust, only ~1.3% of reviewed orders), `Late 1–3`, `Late 4–7`, `Late 8+`. Then compute per category `late_drop = avg_review(baseline) - avg_review(Late 8+)` — the higher it is, the more that category's reviews suffer once delivery slips badly, i.e. the more delivery-sensitive it is. Rank categories by `late_drop` descending — this is the logistics prioritization list. Flag that the very top of the ranked list skews toward low-volume categories where the `Late 8+` bucket has very few orders, so those extreme values should be read as noisy rather than as a stronger signal than the high-volume categories show.
- **Techniques:** CTE.

**Q3 — State delivery-vs-review quadrant**
- **Question:** Which states are underperforming because of delivery, versus underperforming despite good delivery? (The two need different interventions — the first is a logistics fix, the second means the problem is somewhere else, e.g., seller mix or product mix.)
- **Output:** One row per state with on-time delivery rate, avg review score, and a `quadrant` label — `Low OTD + Low Review` (delivery is the story), `High OTD + Low Review` (delivery is NOT the story, investigate further), `Low OTD + High Review` (customers tolerant here, why?), `High OTD + High Review` (healthy). Quadrant thresholds should be the median of each metric across states, stated explicitly.
- **Techniques:** CTE.

**Q4 — Seller experience vs. review score, within category**
- **Question:** Do experienced sellers actually deliver better reviews than new sellers, or does the review problem persist regardless of tenure? This flips the recommendation: if experience fixes it, invest in onboarding; if it doesn't, the problem is structural.
- **Output:** For each seller, compute their tenure at time of their **first order in the dataset** using `MIN(order_purchase_timestamp) OVER (PARTITION BY seller_id)`. Bucket sellers as New (< 6 months in dataset) or Established (≥ 6 months). Then compare avg review score between New and Established sellers **within each category** — one row per (category, tenure_bucket) combination. Report both the per-category comparison and the overall category-controlled difference. Do **not** pool across categories without controlling.
- **Techniques:** Window function (`MIN() OVER PARTITION BY`), CTE.

**Q6 — Seller ranking within category (intervention shortlist)**
- **Question:** Which specific sellers should be flagged for review or intervention, ranked fairly against peers in the same category?
- **Output:** For each seller with ≥ 20 orders (minimum-volume threshold to avoid noise from tiny sellers — state this in the comment), rank within their primary category by avg review score ascending using `RANK() OVER (PARTITION BY category ORDER BY avg_review ASC)`. Output the bottom 20 sellers per category, with seller_id, category, order count, avg review score, % low-review, and rank.
- **Techniques:** Window function (RANK OVER PARTITION BY), CTE.

**Q7 — Freight-burden effect on review, category-controlled**
- **Question:** Do customers punish Olist when freight feels disproportionate to product value — and is that effect real, or is it just a category-mix artifact?
- **Output:** Compute `freight_ratio = freight_value / price` per order. Within each category, bucket orders into freight-ratio terciles using `NTILE(3) OVER (PARTITION BY category ORDER BY freight_ratio)` — so a "high" freight ratio is defined *relative to that category*, not globally. Compare avg review score across the three buckets, per category. Highlight categories where the low-tercile vs. high-tercile review gap is largest.
- **Techniques:** Window function (NTILE OVER PARTITION BY), CTE.

**Q8 — Product-size-adjusted delivery expectation gap**
- **Question:** Which states and sellers are slow *relative to what's reasonable for the product type they ship*, not slow in absolute terms? A seller shipping heavy furniture in 12 days is not slow; a seller shipping cosmetics in 12 days is.
- **Output:** Bucket products by weight into Light / Medium / Heavy (using overall percentiles: bottom third / middle third / top third of `product_weight_g`). For each (category, weight_bucket) combination, compute the median actual delivery days using `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY actual_delivery_days) OVER (PARTITION BY category, weight_bucket)` — or an equivalent windowed median. Then compute per order: `excess_delivery_days = actual_delivery_days - category_weight_median`. Aggregate to state (avg excess) and to seller (avg excess, sellers with ≥ 20 orders only). Rank both. This surfaces slowness that is genuinely bad, filtering out slowness that is inherent to the product mix.
- **Techniques:** Window function (windowed median or PERCENTILE_CONT OVER PARTITION BY), CTE.

### Deliverables for this phase

- All 8 queries run and produce readable tables in `02_sql_analysis.ipynb`, with a 2–3 sentence business-language interpretation below each result (not just "here's the table").
- Same queries exported to `sql/queries.sql` — each with its business-question comment block preserved, and executable independently of the notebook via a DuckDB CLI or Python session pointed at `data/processed/`.
- A short "SQL findings summary" markdown cell at the end of the notebook: 5–8 bullet points naming the concrete numbers surfaced (e.g., "category X has R$ Y in revenue at risk; state Z has high OTD but low reviews, worth investigating further"). This is the raw material for Phase 5's findings & recommendations section — do not skip it.


## 7. Phase 3 — EDA

**Notebook:** `03_eda.ipynb`

Every chart must be preceded by a markdown cell stating the question it answers (referencing the sub-question table in Section 1) and followed by a 2–3 sentence written takeaway. No chart should exist without both.

EDA covers three activities: **summarising** (the descriptive statistics below), **visualising** (the chart set below), and **looking for patterns and problems** (the findings summary at the end of the notebook).

### Descriptive statistics

Mean, median, mode, variance, range, IQR for review score, delivery gap, freight-to-price ratio, and order value — segmented by category and by state. Present as a clean summary table. (Descriptive statistics live in this EDA phase; Phase 4 covers inferential, predictive, and prescriptive analysis only.)

### Charts

Minimum chart set:
- Review score distribution (answers: how big is the problem)
- Revenue by review-score bucket (answers: revenue at risk)
- Boxplot of delivery gap by review score bucket (answers: is late delivery the culprit)
- Scatter of estimated vs. actual delivery date, colored by review score
- Category heatmap: volume × avg review score (answers: where to prioritize)
- State-level bar chart of avg review score and delivery gap
- Monthly time series: avg review score with delivery-time overlay
- Freight-to-price ratio vs. review score

## 8. Phase 4 — Statistical Analysis

**Notebook:** `04_statistical_analysis.ipynb`

This phase covers inferential, predictive, and prescriptive analysis.

### Inferential
For **each** test below: state H₀ and H₁ explicitly in a markdown cell, check relevant assumptions (e.g., normality via QQ plot before defaulting to a t-test; report Shapiro-Wilk or just visually justify), report the test statistic and p-value, and close with one sentence translating the result into a business conclusion.

| Test | Business question |
|---|---|
| Welch's two-sample t-test | Do orders with review ≤ 3 have significantly longer delivery gaps than orders with review ≥ 4? |
| One-way ANOVA + Tukey HSD post-hoc | Do avg review scores differ significantly across the top 6 categories by volume? Which specific category pairs differ? |
| Levene's test | Is delivery-gap variance significantly different between the 5 best-performing and 5 worst-performing states (by avg review)? |
| Chi-square test of independence | Is a high installment count (e.g. > 6) associated with a higher rate of low reviews? |
| Spearman correlation (with p-value) | Is freight-to-price ratio correlated with review score? |

### Predictive
- **Target:** `low_review = 1 if review_score <= 3 else 0`.
- **Features:** delivery_gap_days, actual delivery days, price, freight_value, freight-to-price ratio, category, state, seller historical avg review (computed with a lagged/expanding window to avoid leakage), max_installments, item_count, weekday of purchase.
- **Split:** time-based — train on orders up to a cutoff (e.g. mid-2018), test on the remainder. Do not use a random split; justify why in a markdown cell (leakage/realism).
- **Base model:** Logistic Regression (standardized numeric features, one-hot categoricals). Report Accuracy, Precision, Recall, F1, ROC-AUC, PR-AUC, and confusion matrix.
- **Improved model:** LightGBM with 5-fold stratified cross-validation for hyperparameter tuning (learning_rate, num_leaves, min_child_samples). Report the same metrics side by side with the base model in one comparison table.
- **Explainability:** SHAP summary plot + top-5 feature importances. State explicitly whether SHAP's top drivers agree with the inferential test results (they should largely agree — call this out, it's a strong credibility point).
- **Why the improved model wins:** identify at least one real nonlinear interaction (e.g., a partial dependence or SHAP interaction plot showing delivery gap matters more for certain categories) and state it in words, not just "the AUC went up."

### Prescriptive
- Use the LightGBM model's predicted probability as a risk score.
- Define an intervention threshold (e.g., top-decile risk, or probability > 0.6) and simulate: how many low reviews would this catch, at what volume of orders flagged?
- Translate into an estimated marketplace-wide review score lift if intervention prevented some fraction of flagged low reviews. State the assumption behind the fraction explicitly (this is a simulation, not a guarantee — say so).
- Save order-level risk scores to `outputs/model_risk_scores.parquet` for potential later use in the Power BI dashboard.

## 9. Phase 5 — Key Findings & Recommendations

**Location:** final section of `05_modeling.ipynb`, plus `reports/executive_summary.pdf`

Format every finding as: **Finding → Evidence → Recommendation → Estimated impact.** Pull evidence from the specific test/model result (cite the actual p-value, AUC, or SHAP rank — no vague claims). Aim for 3–5 findings, not more; depth over breadth.

## 10. Deliverables Checklist

- [ ] 5 notebooks, each starting with a markdown cell stating what business question the notebook answers
- [ ] `sql/queries.sql` — standalone, commented, runnable independent of notebooks
- [ ] `data/processed/orders_clean.parquet`
- [ ] `outputs/model_risk_scores.parquet`
- [ ] `reports/figures/` — key charts saved as PNG for reuse in Power BI later
- [ ] `reports/executive_summary.pdf` — 1 page: problem, approach, 3–5 findings, recommendations
- [ ] This README kept up to date with any material changes to scope
- [ ] `requirements.txt` accurate and installable via `pip install -r requirements.txt`

## 11. Explicitly Out of Scope (for now)

- Power BI dashboard — planned as a separate follow-up phase after this project is complete, not part of this repo's initial scope.
- Any productionization (API, scheduled retraining, MLflow tracking) — not relevant to a data analyst portfolio piece and would dilute the story.

## 12. Working Notes for Claude Code

- Work phase by phase in the order above. Do not start Phase 2 until Phase 1's cleaned parquet exists and has been sanity-checked (row counts, no unexpected nulls in key columns).
- If a cleaning or modeling decision would materially change the business narrative (e.g., dropping >5% of orders, changing the low-review threshold from ≤3), stop and ask rather than deciding silently.
- Keep code in `src/` for anything reused across notebooks (e.g., the cleaning pipeline, the seller-historical-avg-review feature with leakage-safe windowing); notebooks should import from `src/`, not redefine logic.
- Every notebook should be runnable top-to-bottom without manual intervention, assuming `data/raw/` is populated and `requirements.txt` is installed.
