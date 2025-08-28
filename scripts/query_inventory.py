from src.database.DatabaseManager import get_database
db = get_database()
print(db.query_df("""
SELECT store, product_name, brand_name
FROM app_inventory
WHERE product_name ~ '[A-Za-z]'
ORDER BY product_name
LIMIT 20
"""))
