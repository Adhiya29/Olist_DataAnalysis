import pandas as pd


def filter_delivered(orders: pd.DataFrame) -> pd.DataFrame:
    return orders[orders["order_status"] == "delivered"].copy()


def compute_delivery_gap(orders: pd.DataFrame) -> pd.DataFrame:
    orders = orders.copy()
    orders["delivery_gap_days"] = (
        orders["order_delivered_customer_date"] - orders["order_estimated_delivery_date"]
    ).dt.days
    return orders


def map_product_categories(
    products: pd.DataFrame, category_translation: pd.DataFrame
) -> pd.DataFrame:
    products = products.merge(category_translation, on="product_category_name", how="left")
    products["category_final"] = products["product_category_name_english"].fillna(
        products["product_category_name"]
    )
    products["category_final"] = products["category_final"].fillna("unknown")
    return products


def aggregate_order_items(order_items: pd.DataFrame) -> pd.DataFrame:
    return order_items.groupby("order_id").agg(
        total_price=("price", "sum"),
        total_freight=("freight_value", "sum"),
        item_count=("order_item_id", "count"),
        distinct_seller_count=("seller_id", "nunique"),
    ).reset_index()


def primary_category_per_order(
    order_items: pd.DataFrame, products_mapped: pd.DataFrame
) -> pd.DataFrame:
    items_with_category = order_items.merge(
        products_mapped[["product_id", "category_final"]], on="product_id", how="left"
    )
    primary = (
        items_with_category.sort_values("price", ascending=False)
        .drop_duplicates(subset="order_id", keep="first")[["order_id", "category_final"]]
        .rename(columns={"category_final": "primary_category"})
    )
    return primary


def aggregate_order_payments(order_payments: pd.DataFrame) -> pd.DataFrame:
    totals = order_payments.groupby("order_id").agg(
        total_payment_value=("payment_value", "sum"),
        max_installments=("payment_installments", "max"),
    ).reset_index()

    primary_method = (
        order_payments.sort_values("payment_value", ascending=False)
        .drop_duplicates(subset="order_id", keep="first")[["order_id", "payment_type"]]
    )
    return totals.merge(primary_method, on="order_id", how="left")


def dedupe_reviews(order_reviews: pd.DataFrame) -> tuple[pd.DataFrame, int]:
    before = len(order_reviews)
    deduped = order_reviews.sort_values("review_answer_timestamp").drop_duplicates(
        subset="order_id", keep="last"
    )
    return deduped, before - len(deduped)


def merge_item_product_attrs(
    order_items: pd.DataFrame, products_mapped: pd.DataFrame
) -> pd.DataFrame:
    return order_items.merge(
        products_mapped[["product_id", "category_final", "product_weight_g"]],
        on="product_id",
        how="left",
    )


def flag_invalid_weight(items: pd.DataFrame) -> pd.Series:
    return items["product_weight_g"].isna() | (items["product_weight_g"] <= 0)


def flag_iqr_outliers(order_items: pd.DataFrame, column: str) -> pd.Series:
    q1, q3 = order_items[column].quantile([0.25, 0.75])
    iqr = q3 - q1
    upper_bound = q3 + 1.5 * iqr
    return order_items[column] > upper_bound
