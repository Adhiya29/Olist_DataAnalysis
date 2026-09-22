from pathlib import Path

import pandas as pd

RAW_DIR = Path("data/raw")

RAW_FILES = {
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}

ORDER_TIMESTAMP_COLS = [
    "order_purchase_timestamp",
    "order_approved_at",
    "order_delivered_carrier_date",
    "order_delivered_customer_date",
    "order_estimated_delivery_date",
]

REVIEW_TIMESTAMP_COLS = ["review_creation_date", "review_answer_timestamp"]


def verify_raw_files_present(raw_dir: Path = RAW_DIR) -> list[str]:
    missing = [fname for fname in RAW_FILES.values() if not (raw_dir / fname).exists()]
    return missing


def load_raw_tables(raw_dir: Path = RAW_DIR) -> dict[str, pd.DataFrame]:
    tables = {name: pd.read_csv(raw_dir / fname) for name, fname in RAW_FILES.items()}

    for col in ORDER_TIMESTAMP_COLS:
        tables["orders"][col] = pd.to_datetime(tables["orders"][col])

    for col in REVIEW_TIMESTAMP_COLS:
        tables["order_reviews"][col] = pd.to_datetime(tables["order_reviews"][col])

    tables["order_items"]["shipping_limit_date"] = pd.to_datetime(
        tables["order_items"]["shipping_limit_date"]
    )

    return tables
