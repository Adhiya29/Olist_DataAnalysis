import numpy as np
import pandas as pd

NUMERIC_FEATURES = [
    "delivery_gap_days",
    "actual_delivery_days",
    "total_payment_value",
    "total_freight",
    "freight_ratio",
    "max_installments",
    "item_count",
    "purchase_weekday",
]

CATEGORICAL_FEATURES = [
    "primary_category",
    "customer_state",
    "payment_type",
]

TARGET = "low_review"


def build_feature_matrix(orders: pd.DataFrame) -> pd.DataFrame:
    df = orders.dropna(subset=["review_score"]).copy()

    df["actual_delivery_days"] = (
        df["order_delivered_customer_date"] - df["order_purchase_timestamp"]
    ).dt.days
    df["freight_ratio"] = df["total_freight"] / df["total_price"].replace(0, np.nan)
    df["purchase_weekday"] = df["order_purchase_timestamp"].dt.weekday
    df["payment_type"] = df["payment_type"].fillna("unknown")
    df[TARGET] = (df["review_score"] <= 3).astype(int)

    keep = (
        ["order_id", "order_purchase_timestamp"]
        + NUMERIC_FEATURES
        + CATEGORICAL_FEATURES
        + [TARGET]
    )
    return df[keep].reset_index(drop=True)


def time_split(features: pd.DataFrame, cutoff: str):
    cutoff_ts = pd.Timestamp(cutoff)
    train = features[features["order_purchase_timestamp"] < cutoff_ts]
    test = features[features["order_purchase_timestamp"] >= cutoff_ts]
    return train.reset_index(drop=True), test.reset_index(drop=True)
