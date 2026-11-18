CREATE TABLE IF NOT EXISTS products (
  id        text COLLATE "C" PRIMARY KEY,
  name      text   NOT NULL,
  category  text   NOT NULL,
  price     bigint NOT NULL CHECK (price >= 0),
  stock     bigint NOT NULL CHECK (stock >= 0)
) WITH (fillfactor = 70);

CREATE INDEX IF NOT EXISTS products_cat_price_id ON products (category, price, id);

CREATE TABLE IF NOT EXISTS orders (
  order_id   text PRIMARY KEY,
  user_id    text NOT NULL,
  product_id text NOT NULL REFERENCES products(id),
  UNIQUE (user_id, product_id)
);
