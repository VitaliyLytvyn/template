INSERT INTO products (name, description, price, stock)
WITH seed AS (
  SELECT 'Running Shoes'       name, 'Lightweight trail running shoes, breathable mesh upper'  description, 89.99  price, 50 stock UNION ALL
  SELECT 'Wireless Headphones',      'Active noise cancellation, 30hr battery, USB-C charging',            199.99,       25        UNION ALL
  SELECT 'Coffee Maker',             'Programmable 12-cup drip coffee maker with thermal carafe',           79.99,       30        UNION ALL
  SELECT 'Yoga Mat',                 'Non-slip 6mm thick TPE mat, includes carry strap',                    34.99,       75        UNION ALL
  SELECT 'Mechanical Keyboard',      'Tenkeyless, tactile switches, RGB backlight, PBT keycaps',          129.99,       40        UNION ALL
  SELECT 'Stainless Water Bottle',   'Insulated 32oz, keeps cold 24h hot 12h, leak-proof lid',             24.99,      100        UNION ALL
  SELECT 'Desk Lamp',                'LED, adjustable color temp and brightness, USB charging port',        49.99,       60        UNION ALL
  SELECT 'Backpack',                 '30L travel backpack, laptop sleeve, water-resistant nylon',           59.99,       35        UNION ALL
  SELECT 'Bluetooth Speaker',        'Waterproof IPX7, 360 sound, 12hr playtime',                          69.99,       45        UNION ALL
  SELECT 'Standing Desk Mat',        'Anti-fatigue foam 30x20in, beveled edges, easy clean',               39.99,       55
)
SELECT name, description, price, stock FROM seed
WHERE (SELECT COUNT(*) FROM products) = 0;
