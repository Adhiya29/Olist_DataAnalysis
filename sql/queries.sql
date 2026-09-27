-- Olist Marketplace -- Phase 2 SQL Analysis
-- Generated from notebooks/02_sql_analysis.ipynb -- run it there for narrative
-- markdown, business-language interpretation, and result tables.
-- Standalone usage: duckdb < sql/queries.sql (from the repo root), or paste
-- individual statements into a DuckDB CLI session pointed at data/processed/.
-- Q5 was intentionally removed (folded into Phase 4's chi-square test).


-- Q0a -- Baseline snapshot (overall)
-- Business question: How large is the low-review problem overall?
-- Grain of result: one row -- the all-time snapshot across all delivered orders.
-- How to read it: pct_low_review is the share of *reviewed* orders (review_score
--   not null) scoring <= 3. total_revenue is product revenue (total_price),
--   excludes freight. Orders without a submitted review count toward
--   total_orders/total_revenue but not the review-based columns.
-- Cross-cutting note: intentionally pools all categories/states -- this is the
--   headline baseline, not a comparison.
WITH base AS (
    SELECT order_id, total_price, review_score
    FROM 'data/processed/orders_clean.parquet'
)
SELECT
    COUNT(*) AS total_orders,
    ROUND(SUM(total_price), 2) AS total_revenue,
    ROUND(AVG(review_score), 3) AS avg_review_score,
    COUNT(*) FILTER (WHERE review_score IS NOT NULL) AS reviewed_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 3)
          / COUNT(*) FILTER (WHERE review_score IS NOT NULL), 2) AS pct_low_review
FROM base;

-- Q0b -- Baseline snapshot (monthly trend)
-- Business question: What has the monthly trend in order volume, review score,
--   and low-review share looked like?
-- Grain of result: one row per calendar month of order_purchase_timestamp.
-- How to read it: same pct_low_review definition as Q0a, computed within each month.
-- Cross-cutting note: pools all categories/states within each month -- this is
--   the headline monthly trend, not a category comparison.
WITH base AS (
    SELECT order_id, date_trunc('month', order_purchase_timestamp) AS order_month, review_score
    FROM 'data/processed/orders_clean.parquet'
)
SELECT
    order_month,
    COUNT(*) AS order_volume,
    ROUND(AVG(review_score), 3) AS avg_review_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 3)
          / COUNT(*) FILTER (WHERE review_score IS NOT NULL), 2) AS pct_low_review
FROM base
GROUP BY order_month
ORDER BY order_month;

-- Q1 -- Category priority matrix
-- Business question: Which product categories should be prioritized for
--   intervention? Weight both size (volume/revenue) and severity (% low-review).
-- Grain of result: one row per primary_category.
-- How to read it: revenue_at_risk = SUM(total_price) WHERE review_score <= 3,
--   i.e. the actual dollars attached to that category's bad-review orders, not
--   an estimate that assumes bad-review orders are average-priced. priority_rank
--   orders categories by revenue_at_risk descending.
-- Cross-cutting note: partitioned by primary_category throughout -- no
--   cross-category pooling.
WITH category_stats AS (
    SELECT
        primary_category,
        COUNT(*) AS order_volume,
        SUM(total_price) AS revenue,
        AVG(review_score) AS avg_review_score,
        COUNT(*) FILTER (WHERE review_score <= 3) * 1.0
            / NULLIF(COUNT(*) FILTER (WHERE review_score IS NOT NULL), 0) AS pct_low_review_rate,
        SUM(total_price) FILTER (WHERE review_score <= 3) AS revenue_at_risk_raw
    FROM 'data/processed/orders_clean.parquet'
    GROUP BY primary_category
),
priority AS (
    SELECT
        primary_category,
        order_volume,
        ROUND(revenue, 2) AS revenue,
        ROUND(avg_review_score, 3) AS avg_review_score,
        ROUND(pct_low_review_rate * 100, 2) AS pct_low_review,
        ROUND(COALESCE(revenue_at_risk_raw, 0), 2) AS revenue_at_risk
    FROM category_stats
)
SELECT *, RANK() OVER (ORDER BY revenue_at_risk DESC) AS priority_rank
FROM priority
ORDER BY priority_rank;

-- Q2 -- Delivery-sensitivity by category
-- Business question: Does late delivery hurt reviews equally across categories?
-- Grain of result: one row per primary_category (categories missing the
--   baseline or Late 8+ bucket entirely are excluded).
-- How to read it: delivery_gap_days = actual - estimated (positive = late).
--   baseline = avg_review where delivery_gap_days <= 0 (early or on-time,
--   merged since the exact on-time day alone is too thin a bucket to trust).
--   late_drop = avg_review(baseline) - avg_review(Late 8+); higher late_drop
--   means that category is more delivery-sensitive. Ranked by late_drop
--   descending (logistics prioritization list).
-- Cross-cutting note: partitioned by primary_category throughout.
WITH bucketed AS (
    SELECT
        primary_category,
        review_score,
        CASE
            WHEN delivery_gap_days <= 0 THEN 'baseline'
            WHEN delivery_gap_days BETWEEN 1 AND 3 THEN 'Late 1-3'
            WHEN delivery_gap_days BETWEEN 4 AND 7 THEN 'Late 4-7'
            ELSE 'Late 8+'
        END AS gap_bucket
    FROM 'data/processed/orders_clean.parquet'
    WHERE review_score IS NOT NULL
),
category_bucket_avg AS (
    SELECT primary_category, gap_bucket, COUNT(*) AS order_count, AVG(review_score) AS avg_review_score
    FROM bucketed
    GROUP BY primary_category, gap_bucket
),
pivoted AS (
    SELECT
        primary_category,
        MAX(avg_review_score) FILTER (WHERE gap_bucket = 'baseline') AS baseline,
        MAX(avg_review_score) FILTER (WHERE gap_bucket = 'Late 1-3') AS late1to3,
        MAX(avg_review_score) FILTER (WHERE gap_bucket = 'Late 4-7') AS late4to7,
        MAX(avg_review_score) FILTER (WHERE gap_bucket = 'Late 8+') AS late8plus,
        SUM(order_count) AS total_orders
    FROM category_bucket_avg
    GROUP BY primary_category
)
SELECT
    primary_category, total_orders,
    ROUND(baseline, 3) AS baseline,
    ROUND(late1to3, 3) AS late1to3, ROUND(late4to7, 3) AS late4to7, ROUND(late8plus, 3) AS late8plus,
    ROUND(baseline - late8plus, 3) AS late_drop
FROM pivoted
WHERE baseline IS NOT NULL AND late8plus IS NOT NULL
ORDER BY late_drop DESC;

-- Q3 -- State delivery-vs-review quadrant
-- Business question: Which states are underperforming because of delivery,
--   versus underperforming despite good delivery?
-- Grain of result: one row per customer_state.
-- How to read it: on_time_rate = share of orders with delivery_gap_days <= 0.
--   Quadrant thresholds are the MEDIAN on_time_rate and MEDIAN avg_review_score
--   across states (computed in the medians CTE), not a fixed cutoff.
-- Cross-cutting note: pools across product categories within each state --
--   justified because this is a geographic/logistics axis, not a product axis;
--   category-level analysis is Q1/Q2's job. A category-mix confound across
--   states is possible but out of scope here (see Phase 4 Levene's test).
WITH state_stats AS (
    SELECT
        customer_state,
        COUNT(*) AS order_volume,
        AVG(review_score) AS avg_review_score,
        100.0 * COUNT(*) FILTER (WHERE delivery_gap_days <= 0) / COUNT(*) AS on_time_rate
    FROM 'data/processed/orders_clean.parquet'
    WHERE review_score IS NOT NULL
    GROUP BY customer_state
),
medians AS (
    SELECT MEDIAN(on_time_rate) AS median_otd, MEDIAN(avg_review_score) AS median_review
    FROM state_stats
)
SELECT
    s.customer_state, s.order_volume,
    ROUND(s.on_time_rate, 2) AS on_time_rate,
    ROUND(s.avg_review_score, 3) AS avg_review_score,
    CASE
        WHEN s.on_time_rate < m.median_otd AND s.avg_review_score < m.median_review THEN 'Low OTD + Low Review'
        WHEN s.on_time_rate >= m.median_otd AND s.avg_review_score < m.median_review THEN 'High OTD + Low Review'
        WHEN s.on_time_rate < m.median_otd AND s.avg_review_score >= m.median_review THEN 'Low OTD + High Review'
        ELSE 'High OTD + High Review'
    END AS quadrant
FROM state_stats s CROSS JOIN medians m
ORDER BY s.order_volume DESC;

-- Q4 -- Seller experience vs. review score, within category
-- Business question: Do experienced sellers deliver better reviews than new
--   sellers, or does the problem persist regardless of tenure?
-- Grain of result: one row per (category, tenure_bucket).
-- How to read it: seller_first_order = MIN(order_purchase_timestamp) OVER
--   (PARTITION BY seller_id). JUDGMENT CALL: "tenure in the dataset" is
--   operationalized as (dataset's last order date - seller's first order date),
--   i.e. how long the seller has been observed overall, not a per-order
--   lookback. >= 182 days (~6 months) = Established, else New.
-- Cross-cutting note: partitioned by category; see Q4_OVERALL_SQL below for
--   the category-controlled overall figure (a weighted average of
--   within-category differences, not a pooled cross-category comparison).
WITH item_reviews AS (
    SELECT seller_id, category, order_id, order_purchase_timestamp, review_score
    FROM 'data/processed/order_items_clean.parquet'
    WHERE review_score IS NOT NULL
),
seller_tenure AS (
    SELECT *,
        MIN(order_purchase_timestamp) OVER (PARTITION BY seller_id) AS seller_first_order,
        MAX(order_purchase_timestamp) OVER () AS dataset_last_order
    FROM item_reviews
),
bucketed AS (
    SELECT *,
        CASE WHEN date_diff('day', seller_first_order, dataset_last_order) < 182
             THEN 'New' ELSE 'Established' END AS tenure_bucket
    FROM seller_tenure
)
SELECT
    category, tenure_bucket,
    COUNT(DISTINCT seller_id) AS seller_count,
    COUNT(*) AS order_item_count,
    ROUND(AVG(review_score), 3) AS avg_review_score
FROM bucketed
GROUP BY category, tenure_bucket
ORDER BY category, tenure_bucket;

-- Q4 (continued) -- category-controlled overall tenure effect
-- Business question: same as Q4_breakdown -- this collapses it to one number.
-- Grain of result: one row -- the volume-weighted average, across categories,
--   of (avg_review[Established] - avg_review[New]).
-- How to read it: NOT a pooled average of raw review scores across categories
--   (that would risk Simpson's paradox) -- it's a weighted average of
--   WITHIN-category differences, weighted by each category's order-item count.
--   Only categories with both a New and an Established seller present
--   contribute.
WITH item_reviews AS (
    SELECT seller_id, category, order_id, order_purchase_timestamp, review_score
    FROM 'data/processed/order_items_clean.parquet'
    WHERE review_score IS NOT NULL
),
seller_tenure AS (
    SELECT *,
        MIN(order_purchase_timestamp) OVER (PARTITION BY seller_id) AS seller_first_order,
        MAX(order_purchase_timestamp) OVER () AS dataset_last_order
    FROM item_reviews
),
bucketed AS (
    SELECT *,
        CASE WHEN date_diff('day', seller_first_order, dataset_last_order) < 182
             THEN 'New' ELSE 'Established' END AS tenure_bucket
    FROM seller_tenure
),
category_bucket AS (
    SELECT category, tenure_bucket, COUNT(*) AS n, AVG(review_score) AS avg_review
    FROM bucketed
    GROUP BY category, tenure_bucket
),
category_diff AS (
    SELECT
        category,
        MAX(avg_review) FILTER (WHERE tenure_bucket = 'Established')
            - MAX(avg_review) FILTER (WHERE tenure_bucket = 'New') AS established_minus_new,
        SUM(n) AS category_n
    FROM category_bucket
    GROUP BY category
)
SELECT
    COUNT(*) AS categories_with_both_buckets,
    ROUND(SUM(established_minus_new * category_n) / SUM(category_n), 4) AS overall_category_controlled_diff
FROM category_diff
WHERE established_minus_new IS NOT NULL;

-- Q6 -- Seller ranking within category (intervention shortlist)
-- Business question: Which specific sellers should be flagged for review or
--   intervention, ranked fairly against peers in the same category?
-- Grain of result: one row per (seller, category) -- bottom 20 sellers per
--   primary category, sellers with >= 20 orders only (minimum-volume threshold
--   to avoid noise from tiny sellers).
-- How to read it: primary_category = the category a seller has shipped the
--   most distinct orders in. Stats are computed after de-duplicating to one
--   row per (seller, order), so multi-item orders from the same seller aren't
--   double-counted. category_rank = RANK() OVER (PARTITION BY primary_category
--   ORDER BY avg_review_score ASC); only rank <= 20 shown.
-- Cross-cutting note: partitioned by primary_category throughout.
WITH seller_orders AS (
    SELECT DISTINCT seller_id, order_id, review_score
    FROM 'data/processed/order_items_clean.parquet'
),
seller_category_counts AS (
    SELECT seller_id, category, COUNT(DISTINCT order_id) AS orders_in_category
    FROM 'data/processed/order_items_clean.parquet'
    GROUP BY seller_id, category
),
seller_primary_category AS (
    SELECT seller_id, category AS primary_category
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY orders_in_category DESC) AS rn
        FROM seller_category_counts
    )
    WHERE rn = 1
),
seller_stats AS (
    SELECT
        seller_id,
        COUNT(*) AS order_count,
        AVG(review_score) AS avg_review_score,
        100.0 * COUNT(*) FILTER (WHERE review_score <= 3)
            / NULLIF(COUNT(*) FILTER (WHERE review_score IS NOT NULL), 0) AS pct_low_review
    FROM seller_orders
    GROUP BY seller_id
    HAVING COUNT(*) >= 20
),
ranked AS (
    SELECT
        s.seller_id, p.primary_category, s.order_count,
        ROUND(s.avg_review_score, 3) AS avg_review_score,
        ROUND(s.pct_low_review, 2) AS pct_low_review,
        RANK() OVER (PARTITION BY p.primary_category ORDER BY s.avg_review_score ASC) AS category_rank
    FROM seller_stats s
    JOIN seller_primary_category p ON s.seller_id = p.seller_id
)
SELECT * FROM ranked WHERE category_rank <= 20
ORDER BY primary_category, category_rank;

-- Q7 -- Freight-burden effect on review, category-controlled
-- Business question: Do customers punish Olist when freight feels
--   disproportionate to product value -- and is that a real effect or a
--   category-mix artifact?
-- Grain of result: one row per primary_category.
-- How to read it: freight_ratio = total_freight / total_price per order.
--   NTILE(3) OVER (PARTITION BY primary_category ORDER BY freight_ratio) buckets
--   orders into terciles relative to their OWN category. low_minus_high_gap =
--   avg_review(low freight tercile) - avg_review(high freight tercile).
-- Cross-cutting note: terciles are computed PARTITION BY primary_category, so
--   no order is compared to a peer outside its own category.
WITH freight AS (
    SELECT order_id, primary_category, review_score,
           total_freight / NULLIF(total_price, 0) AS freight_ratio
    FROM 'data/processed/orders_clean.parquet'
    WHERE review_score IS NOT NULL AND total_price > 0
),
terciled AS (
    SELECT *, NTILE(3) OVER (PARTITION BY primary_category ORDER BY freight_ratio) AS freight_tercile
    FROM freight
),
category_tercile AS (
    SELECT primary_category, freight_tercile, COUNT(*) AS order_count, AVG(review_score) AS avg_review_score
    FROM terciled
    GROUP BY primary_category, freight_tercile
),
pivoted AS (
    SELECT
        primary_category,
        MAX(avg_review_score) FILTER (WHERE freight_tercile = 1) AS avg_review_low_freight,
        MAX(avg_review_score) FILTER (WHERE freight_tercile = 2) AS avg_review_mid_freight,
        MAX(avg_review_score) FILTER (WHERE freight_tercile = 3) AS avg_review_high_freight,
        SUM(order_count) AS total_orders
    FROM category_tercile
    GROUP BY primary_category
)
SELECT
    primary_category, total_orders,
    ROUND(avg_review_low_freight, 3) AS avg_review_low_freight,
    ROUND(avg_review_mid_freight, 3) AS avg_review_mid_freight,
    ROUND(avg_review_high_freight, 3) AS avg_review_high_freight,
    ROUND(avg_review_low_freight - avg_review_high_freight, 3) AS low_minus_high_gap
FROM pivoted
ORDER BY low_minus_high_gap DESC;

-- Q8 -- Product-size-adjusted delivery expectation gap
-- Business question: Which states/sellers are slow relative to what's
--   reasonable for the product type they ship, not slow in absolute terms?
-- Grain of result: one row per order line item (base CTE chain below), then
--   aggregated to state and to seller (>= 20 orders) in the two queries after it.
-- How to read it: weight_bucket = Light/Medium/Heavy by overall percentiles of
--   product_weight_g (item-grain, i.e. shipment-weighted, not catalog-weighted).
--   category_weight_median = MEDIAN(actual_delivery_days) OVER (PARTITION BY
--   category, weight_bucket) -- DuckDB's windowed MEDIAN, used as the README's
--   allowed "equivalent windowed median" to PERCENTILE_CONT(0.5) WITHIN GROUP.
--   excess_delivery_days = actual_delivery_days - category_weight_median;
--   positive = slower than normal for that category+weight combination.
-- Cross-cutting note: the median baseline is PARTITION BY category,
--   weight_bucket, so slowness is measured against a category-and-size-
--   appropriate norm, not one global delivery-time baseline.
WITH weight_buckets AS (
    SELECT *, NTILE(3) OVER (ORDER BY product_weight_g) AS weight_tercile
    FROM 'data/processed/order_items_clean.parquet'
),
labeled AS (
    SELECT *, CASE weight_tercile WHEN 1 THEN 'Light' WHEN 2 THEN 'Medium' ELSE 'Heavy' END AS weight_bucket
    FROM weight_buckets
),
with_median AS (
    SELECT *,
        MEDIAN(actual_delivery_days) OVER (PARTITION BY category, weight_bucket) AS category_weight_median
    FROM labeled
),
with_excess AS (
    SELECT *, actual_delivery_days - category_weight_median AS excess_delivery_days
    FROM with_median
)

SELECT weight_bucket, COUNT(*) AS n, MIN(product_weight_g) AS min_g, MAX(product_weight_g) AS max_g,
       ROUND(AVG(excess_delivery_days), 3) AS avg_excess_delivery_days
FROM with_excess
GROUP BY weight_bucket
ORDER BY min_g;

-- Q8 (continued) -- aggregated to state
-- Grain of result: one row per customer_state.
-- How to read it: avg_excess_delivery_days averaged across order LINE ITEMS in
--   that state (an order with 3 items from 3 sellers contributes 3 rows) --
--   consistent with this query's item-grain source per the Section 6 grain
--   reminder. slowness_rank ranks states from slowest to fastest.
WITH weight_buckets AS (
    SELECT *, NTILE(3) OVER (ORDER BY product_weight_g) AS weight_tercile
    FROM 'data/processed/order_items_clean.parquet'
),
labeled AS (
    SELECT *, CASE weight_tercile WHEN 1 THEN 'Light' WHEN 2 THEN 'Medium' ELSE 'Heavy' END AS weight_bucket
    FROM weight_buckets
),
with_median AS (
    SELECT *,
        MEDIAN(actual_delivery_days) OVER (PARTITION BY category, weight_bucket) AS category_weight_median
    FROM labeled
),
with_excess AS (
    SELECT *, actual_delivery_days - category_weight_median AS excess_delivery_days
    FROM with_median
)

SELECT
    customer_state,
    COUNT(*) AS item_rows,
    COUNT(DISTINCT order_id) AS order_count,
    ROUND(AVG(excess_delivery_days), 2) AS avg_excess_delivery_days,
    RANK() OVER (ORDER BY AVG(excess_delivery_days) DESC) AS slowness_rank
FROM with_excess
GROUP BY customer_state
ORDER BY slowness_rank;

-- Q8 (continued) -- aggregated to seller, minimum-volume filtered
-- Grain of result: one row per seller, sellers with >= 20 orders only (same
--   minimum-volume threshold as Q6, to avoid noise from tiny sellers).
-- How to read it: same excess_delivery_days definition as Q8_by_state.
--   Top 20 slowest sellers shown -- an intervention shortlist.
WITH weight_buckets AS (
    SELECT *, NTILE(3) OVER (ORDER BY product_weight_g) AS weight_tercile
    FROM 'data/processed/order_items_clean.parquet'
),
labeled AS (
    SELECT *, CASE weight_tercile WHEN 1 THEN 'Light' WHEN 2 THEN 'Medium' ELSE 'Heavy' END AS weight_bucket
    FROM weight_buckets
),
with_median AS (
    SELECT *,
        MEDIAN(actual_delivery_days) OVER (PARTITION BY category, weight_bucket) AS category_weight_median
    FROM labeled
),
with_excess AS (
    SELECT *, actual_delivery_days - category_weight_median AS excess_delivery_days
    FROM with_median
)

SELECT
    seller_id,
    COUNT(DISTINCT order_id) AS order_count,
    ROUND(AVG(excess_delivery_days), 2) AS avg_excess_delivery_days,
    RANK() OVER (ORDER BY AVG(excess_delivery_days) DESC) AS slowness_rank
FROM with_excess
GROUP BY seller_id
HAVING COUNT(DISTINCT order_id) >= 20
ORDER BY slowness_rank
LIMIT 20;
