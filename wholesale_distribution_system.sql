/* =====================================================================
   WHOLESALE DISTRIBUTION MANAGEMENT SYSTEM
   Smart Supply Chain & Inventory Management  |  MySQL 8.0+
   ---------------------------------------------------------------------
   HOW TO RUN
     Command line :  mysql -u root -p < wholesale_distribution_system.sql
     VS Code      :  open this file, connect with a MySQL extension
                     (e.g. "MySQL" by Weijan Chen or "SQLTools"),
                     then "Run on active connection" to run the whole file.
     Workbench    :  File > Open SQL Script > run (lightning bolt).

   The script is RE-RUNNABLE: it drops and rebuilds database wholesale_db.

   FILE MAP
     PART 1  Database, tables, keys, constraints
     PART 2  Sample data
     PART 3  Data verification checks
     PART 4  Views (saved queries)
     PART 5  The 8 business queries
     PART 6  Extra feature queries (expiry, backup suppliers, tracking)
     PART 7  Joins, subqueries and window-function showcase
     PART 8  Indexing + EXPLAIN (query optimisation)
     PART 9  INSERT / UPDATE / DELETE operations
     PART 10 Transactions (COMMIT / ROLLBACK / SAVEPOINT)

   IMPORTANT - THE "REPORTING DATE"
     Sample data is built around a fixed date, 2026-11-10, so that every
     result shown in the README is reproducible on any day. The function
     fn_today() returns that date. In a live system, change its body to
     RETURN CURDATE();  and all views/queries become "live".
   ===================================================================== */


/* =====================================================================
   PART 1 : DATABASE & TABLE CREATION
   ===================================================================== */

DROP DATABASE IF EXISTS wholesale_db;
CREATE DATABASE wholesale_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE wholesale_db;

-- Reporting-date helper (see note in the header).
DROP FUNCTION IF EXISTS fn_today;
CREATE FUNCTION fn_today() RETURNS DATE DETERMINISTIC
    RETURN DATE('2026-11-10');


/* ---------- 1.1 Suppliers : companies we BUY from ---------------------
   rating is the overall relationship rating (1.0 - 5.0).
   is_active = 0 means we should not place new orders with them.        */
CREATE TABLE Suppliers (
    supplier_id  INT            NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100)   NOT NULL,
    location     VARCHAR(100)   NOT NULL,
    rating       DECIMAL(2,1)   NOT NULL DEFAULT 3.0,
    is_active    TINYINT(1)     NOT NULL DEFAULT 1,
    CONSTRAINT pk_suppliers        PRIMARY KEY (supplier_id),
    CONSTRAINT uq_suppliers_name   UNIQUE (name),
    CONSTRAINT chk_supplier_rating CHECK (rating BETWEEN 1.0 AND 5.0)
) ENGINE=InnoDB;

/* ---------- 1.2 Manufacturers : companies that MAKE the products ------ */
CREATE TABLE Manufacturers (
    manufacturer_id INT           NOT NULL AUTO_INCREMENT,
    name            VARCHAR(100)  NOT NULL,
    location        VARCHAR(100)  NOT NULL,
    CONSTRAINT pk_manufacturers      PRIMARY KEY (manufacturer_id),
    CONSTRAINT uq_manufacturers_name UNIQUE (name)
) ENGINE=InnoDB;

/* ---------- 1.3 Products : the catalogue ------------------------------
   price = our standard selling (list) price in INR.
   is_perishable = 1 means the product has an expiry date (see batches). */
CREATE TABLE Products (
    product_id      INT            NOT NULL AUTO_INCREMENT,
    product_name    VARCHAR(100)   NOT NULL,
    category        VARCHAR(50)    NOT NULL,
    price           DECIMAL(10,2)  NOT NULL,
    unit            VARCHAR(30)    NOT NULL DEFAULT 'piece',
    is_perishable   TINYINT(1)     NOT NULL DEFAULT 0,
    manufacturer_id INT            NOT NULL,
    CONSTRAINT pk_products       PRIMARY KEY (product_id),
    CONSTRAINT uq_products_name  UNIQUE (product_name),
    CONSTRAINT chk_product_price CHECK (price > 0),
    CONSTRAINT fk_products_manufacturer
        FOREIGN KEY (manufacturer_id) REFERENCES Manufacturers (manufacturer_id)
) ENGINE=InnoDB;

/* ---------- 1.4 Warehouses : where stock is stored --------------------
   capacity is measured in units (pieces / packs / cases).               */
CREATE TABLE Warehouses (
    warehouse_id INT           NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100)  NOT NULL,
    location     VARCHAR(100)  NOT NULL,
    capacity     INT           NOT NULL,
    CONSTRAINT pk_warehouses       PRIMARY KEY (warehouse_id),
    CONSTRAINT uq_warehouses_name  UNIQUE (name),
    CONSTRAINT chk_wh_capacity     CHECK (capacity > 0)
) ENGINE=InnoDB;

/* ---------- 1.5 Customers : schools, universities, offices, shops ----- */
CREATE TABLE Customers (
    customer_id   INT           NOT NULL AUTO_INCREMENT,
    name          VARCHAR(100)  NOT NULL,
    customer_type ENUM('School','University','Corporate Office','Small Business') NOT NULL,
    location      VARCHAR(100)  NOT NULL,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id)
) ENGINE=InnoDB;

/* ---------- 1.6 Transport_Methods : how shipments travel ------------- */
CREATE TABLE Transport_Methods (
    method_id            INT          NOT NULL AUTO_INCREMENT,
    method_name          VARCHAR(50)  NOT NULL,
    typical_speed_kmph   INT          NOT NULL,
    CONSTRAINT pk_transport_methods PRIMARY KEY (method_id),
    CONSTRAINT uq_transport_name    UNIQUE (method_name),
    CONSTRAINT chk_transport_speed  CHECK (typical_speed_kmph > 0)
) ENGINE=InnoDB;

/* ---------- 1.7 Supplier_Products : price list of every supplier ------
   Which supplier can sell which product, at what price, how fast, and
   with what quality. This is the table behind supplier ranking and
   backup-supplier look-ups.  (Resolves the many-to-many between
   Suppliers and Products.)                                              */
CREATE TABLE Supplier_Products (
    supplier_id     INT            NOT NULL,
    product_id      INT            NOT NULL,
    unit_price      DECIMAL(10,2)  NOT NULL,   -- price WE pay the supplier
    lead_time_days  INT            NOT NULL,   -- typical days to deliver
    quality_score   DECIMAL(2,1)   NOT NULL,   -- 1.0 (poor) - 5.0 (excellent)
    CONSTRAINT pk_supplier_products PRIMARY KEY (supplier_id, product_id),
    CONSTRAINT fk_sp_supplier FOREIGN KEY (supplier_id) REFERENCES Suppliers (supplier_id),
    CONSTRAINT fk_sp_product  FOREIGN KEY (product_id)  REFERENCES Products (product_id),
    CONSTRAINT chk_sp_price   CHECK (unit_price > 0),
    CONSTRAINT chk_sp_lead    CHECK (lead_time_days > 0),
    CONSTRAINT chk_sp_quality CHECK (quality_score BETWEEN 1.0 AND 5.0)
) ENGINE=InnoDB;

/* ---------- 1.8 Inventory : current stock of a product in a warehouse
   One row per (warehouse, product) pair - enforced by the UNIQUE key.   */
CREATE TABLE Inventory (
    inventory_id  INT       NOT NULL AUTO_INCREMENT,
    warehouse_id  INT       NOT NULL,
    product_id    INT       NOT NULL,
    quantity      INT       NOT NULL DEFAULT 0,
    reorder_level INT       NOT NULL,
    last_updated  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_inventory PRIMARY KEY (inventory_id),
    CONSTRAINT uq_inventory_wh_product UNIQUE (warehouse_id, product_id),
    CONSTRAINT fk_inventory_warehouse FOREIGN KEY (warehouse_id) REFERENCES Warehouses (warehouse_id),
    CONSTRAINT fk_inventory_product   FOREIGN KEY (product_id)   REFERENCES Products (product_id),
    CONSTRAINT chk_inventory_qty      CHECK (quantity >= 0),
    CONSTRAINT chk_inventory_reorder  CHECK (reorder_level > 0)
) ENGINE=InnoDB;

/* ---------- 1.9 Inventory_Batches : expiry dates of perishable stock --
   The composite foreign key guarantees a batch can only exist for a
   product that is actually stocked in that warehouse.                   */
CREATE TABLE Inventory_Batches (
    batch_id      INT          NOT NULL AUTO_INCREMENT,
    warehouse_id  INT          NOT NULL,
    product_id    INT          NOT NULL,
    batch_no      VARCHAR(30)  NOT NULL,
    quantity      INT          NOT NULL,
    expiry_date   DATE         NOT NULL,
    CONSTRAINT pk_batches PRIMARY KEY (batch_id),
    CONSTRAINT uq_batch_no UNIQUE (warehouse_id, product_id, batch_no),
    CONSTRAINT fk_batches_inventory FOREIGN KEY (warehouse_id, product_id)
        REFERENCES Inventory (warehouse_id, product_id),
    CONSTRAINT chk_batch_qty CHECK (quantity > 0)
) ENGINE=InnoDB;

/* ---------- 1.10 Purchase_Orders : orders WE place with suppliers ----- */
CREATE TABLE Purchase_Orders (
    order_id                INT   NOT NULL AUTO_INCREMENT,
    supplier_id             INT   NOT NULL,
    warehouse_id            INT   NOT NULL,       -- where goods will be delivered
    order_date              DATE  NOT NULL,
    expected_delivery_date  DATE  NOT NULL,
    status ENUM('Placed','Approved','Shipped','Delivered','Cancelled')
                                  NOT NULL DEFAULT 'Placed',
    CONSTRAINT pk_purchase_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_po_supplier  FOREIGN KEY (supplier_id)  REFERENCES Suppliers (supplier_id),
    CONSTRAINT fk_po_warehouse FOREIGN KEY (warehouse_id) REFERENCES Warehouses (warehouse_id),
    CONSTRAINT chk_po_dates    CHECK (expected_delivery_date >= order_date)
) ENGINE=InnoDB;

/* ---------- 1.11 Order_Items : the product lines inside an order ------
   unit_price is copied at order time (prices change later).
   received_quantity < quantity  => short / partial delivery.            */
CREATE TABLE Order_Items (
    order_item_id     INT            NOT NULL AUTO_INCREMENT,
    order_id          INT            NOT NULL,
    product_id        INT            NOT NULL,
    quantity          INT            NOT NULL,
    unit_price        DECIMAL(10,2)  NOT NULL,
    received_quantity INT            NOT NULL DEFAULT 0,
    CONSTRAINT pk_order_items PRIMARY KEY (order_item_id),
    CONSTRAINT uq_order_product UNIQUE (order_id, product_id),
    CONSTRAINT fk_oi_order   FOREIGN KEY (order_id)   REFERENCES Purchase_Orders (order_id)
                             ON DELETE CASCADE,        -- delete order => delete its lines
    CONSTRAINT fk_oi_product FOREIGN KEY (product_id) REFERENCES Products (product_id),
    CONSTRAINT chk_oi_qty      CHECK (quantity > 0),
    CONSTRAINT chk_oi_price    CHECK (unit_price > 0),
    CONSTRAINT chk_oi_received CHECK (received_quantity >= 0 AND received_quantity <= quantity)
) ENGINE=InnoDB;

/* ---------- 1.12 Logistics : one shipment per purchase order ----------
   delivery_date stays NULL while the shipment is still in transit.      */
CREATE TABLE Logistics (
    shipment_id     INT            NOT NULL AUTO_INCREMENT,
    order_id        INT            NOT NULL,
    method_id       INT            NOT NULL,
    distance_km     INT            NOT NULL,
    transport_cost  DECIMAL(10,2)  NOT NULL,
    dispatch_date   DATE           NOT NULL,
    delivery_date   DATE           NULL,
    status          ENUM('In Transit','Delivered') NOT NULL DEFAULT 'In Transit',
    CONSTRAINT pk_logistics PRIMARY KEY (shipment_id),
    CONSTRAINT uq_logistics_order UNIQUE (order_id),          -- 1 order : 1 shipment
    CONSTRAINT fk_log_order  FOREIGN KEY (order_id)  REFERENCES Purchase_Orders (order_id),
    CONSTRAINT fk_log_method FOREIGN KEY (method_id) REFERENCES Transport_Methods (method_id),
    CONSTRAINT chk_log_distance CHECK (distance_km > 0),
    CONSTRAINT chk_log_cost     CHECK (transport_cost >= 0),
    CONSTRAINT chk_log_dates    CHECK (delivery_date IS NULL OR delivery_date >= dispatch_date)
) ENGINE=InnoDB;

/* ---------- 1.13 Stock_Movements : the stock ledger -------------------
   Every IN (goods received) and OUT (goods sold) is one row.
   IN  rows point to a purchase order (or are an opening balance).
   OUT rows point to the customer who bought the goods.
   Rule: current Inventory.quantity = SUM(IN) - SUM(OUT).               */
CREATE TABLE Stock_Movements (
    movement_id    BIGINT       NOT NULL AUTO_INCREMENT,
    warehouse_id   INT          NOT NULL,
    product_id     INT          NOT NULL,
    movement_type  ENUM('IN','OUT') NOT NULL,
    quantity       INT          NOT NULL,
    movement_date  DATE         NOT NULL,
    order_id       INT          NULL,     -- only for IN  (purchase order)
    customer_id    INT          NULL,     -- only for OUT (customer sale)
    remarks        VARCHAR(100) NULL,
    CONSTRAINT pk_stock_movements PRIMARY KEY (movement_id),
    CONSTRAINT fk_sm_warehouse FOREIGN KEY (warehouse_id) REFERENCES Warehouses (warehouse_id),
    CONSTRAINT fk_sm_product   FOREIGN KEY (product_id)   REFERENCES Products (product_id),
    CONSTRAINT fk_sm_order     FOREIGN KEY (order_id)     REFERENCES Purchase_Orders (order_id),
    CONSTRAINT fk_sm_customer  FOREIGN KEY (customer_id)  REFERENCES Customers (customer_id),
    CONSTRAINT chk_sm_qty      CHECK (quantity > 0),
    CONSTRAINT chk_sm_link     CHECK (
        (movement_type = 'IN'  AND customer_id IS NULL) OR
        (movement_type = 'OUT' AND order_id    IS NULL))
) ENGINE=InnoDB;


/* =====================================================================
   PART 2 : SAMPLE DATA   (currency: Indian Rupees)
   ===================================================================== */

-- 2.1 Manufacturers
INSERT INTO Manufacturers (manufacturer_id, name, location) VALUES
(1, 'Ganga Paper Mills',      'Kanpur'),
(2, 'Kalam Stationery Works', 'Delhi'),
(3, 'Technova Electronics',   'Noida'),
(4, 'PureHome Care',          'Ahmedabad'),
(5, 'FreshLeaf Foods',        'Lucknow'),
(6, 'Orion Furniture Co.',    'Jaipur'),
(7, 'LabEdge Scientific',     'Mumbai');

-- 2.2 Products  (price = list price, INR)
INSERT INTO Products (product_id, product_name, category, price, unit, is_perishable, manufacturer_id) VALUES
( 1, 'A4 Copier Paper (500 sheets)', 'Paper',         285.00, 'ream',  0, 1),
( 2, 'Spiral Notebook 200 pg',       'Stationery',     60.00, 'piece', 0, 1),
( 3, 'Ballpoint Pens (box of 50)',   'Stationery',    250.00, 'box',   0, 2),
( 4, 'Whiteboard Markers (12)',      'Stationery',    240.00, 'pack',  0, 2),
( 5, 'Heavy Duty Stapler',           'Office Supplies',350.00,'piece', 0, 2),
( 6, 'Printer Toner Cartridge',      'Electronics',  2800.00, 'piece', 0, 3),
( 7, 'USB Flash Drive 32GB',         'Electronics',   420.00, 'piece', 0, 3),
( 8, 'Scientific Calculator',        'Electronics',   750.00, 'piece', 0, 3),
( 9, 'Hand Sanitizer 500ml',         'Cleaning',      190.00, 'bottle',1, 4),
(10, 'Floor Cleaner 5L',             'Cleaning',      520.00, 'can',   0, 4),
(11, 'Disinfectant Wipes',           'Cleaning',      260.00, 'tub',   1, 4),
(12, 'Instant Coffee 200g',          'Pantry',        480.00, 'jar',   1, 5),
(13, 'Tea Bags (box of 100)',        'Pantry',        220.00, 'box',   1, 5),
(14, 'Bottled Water 1L (case of 12)','Pantry',        240.00, 'case',  1, 5),
(15, 'Student Desk',                 'Furniture',    2600.00, 'piece', 0, 6),
(16, 'Office Chair',                 'Furniture',    4200.00, 'piece', 0, 6),
(17, 'Lab Safety Goggles',           'Lab Supplies',  150.00, 'piece', 0, 7),
(18, 'Chemistry Glassware Set',      'Lab Supplies', 1800.00, 'set',   0, 7);

-- 2.3 Suppliers   (supplier 6 is INACTIVE: no new orders should go to them)
INSERT INTO Suppliers (supplier_id, name, location, rating, is_active) VALUES
(1, 'Sharma Trading Co.',      'Delhi',    4.5, 1),
(2, 'Bharat Wholesale Mart',   'Mumbai',   4.2, 1),
(3, 'Kanpur Office Depot',     'Kanpur',   4.0, 1),
(4, 'Lucknow Supply House',    'Lucknow',  3.6, 1),
(5, 'Metro Distributors',      'Kolkata',  4.7, 1),
(6, 'Southern Traders',        'Chennai',  3.3, 0);

-- 2.4 Warehouses
INSERT INTO Warehouses (warehouse_id, name, location, capacity) VALUES
(1, 'Kanpur Central Warehouse', 'Kanpur',  15000),
(2, 'Delhi North Hub',          'Delhi',    8000),
(3, 'Lucknow Depot',            'Lucknow',  6000),
(4, 'Mumbai West Warehouse',    'Mumbai',   7000);

-- 2.5 Customers
INSERT INTO Customers (customer_id, name, customer_type, location) VALUES
( 1, 'Delhi Model School',          'School',           'Delhi'),
( 2, 'Lucknow Public School',       'School',           'Lucknow'),
( 3, 'Kanpur Vidya Mandir',         'School',           'Kanpur'),
( 4, 'Mumbai International School', 'School',           'Mumbai'),
( 5, 'Ganga University',            'University',       'Kanpur'),
( 6, 'Awadh Technical University',  'University',       'Lucknow'),
( 7, 'Western India Institute',     'University',       'Mumbai'),
( 8, 'Infratek Solutions',          'Corporate Office', 'Delhi'),
( 9, 'BlueOak Consulting',          'Corporate Office', 'Mumbai'),
(10, 'Nexa Finserv',                'Corporate Office', 'Kanpur'),
(11, 'Gupta Stationers & Gifts',    'Small Business',   'Kanpur'),
(12, 'Sunrise Coaching Centre',     'Small Business',   'Lucknow');

-- 2.6 Transport methods
INSERT INTO Transport_Methods (method_id, method_name, typical_speed_kmph) VALUES
(1, 'Road - Heavy Truck', 45),
(2, 'Rail Freight',       35),
(3, 'Air Cargo',         600),
(4, 'Road - Mini Truck',  40);

-- 2.7 Supplier price list: (supplier, product, price WE pay, lead days, quality)
INSERT INTO Supplier_Products (supplier_id, product_id, unit_price, lead_time_days, quality_score) VALUES
-- Product 1  A4 paper
(1, 1,  208.00, 3, 4.5), (2, 1,  202.00, 6, 4.2), (3, 1,  212.00, 2, 4.0), (6, 1,  198.00, 9, 3.2),
-- Product 2  Notebook
(1, 2,   44.00, 3, 4.5), (3, 2,   42.00, 2, 4.0), (4, 2,   41.00, 4, 3.5), (6, 2,   40.00,10, 3.0),
-- Product 3  Pens
(1, 3,  182.00, 3, 4.6), (2, 3,  176.00, 6, 4.3), (3, 3,  185.00, 2, 4.0),
-- Product 4  Markers
(1, 4,  175.00, 3, 4.5), (3, 4,  170.00, 2, 4.1), (4, 4,  168.00, 4, 3.6),
-- Product 5  Stapler
(1, 5,  255.00, 3, 4.4), (3, 5,  248.00, 2, 4.0),
-- Product 6  Toner
(1, 6, 2100.00, 4, 4.6), (2, 6, 2040.00, 7, 4.3), (5, 6, 2060.00, 5, 4.8),
-- Product 7  USB drive
(1, 7,  310.00, 4, 4.5), (2, 7,  295.00, 7, 4.2),
-- Product 8  Calculator
(2, 8,  535.00, 6, 4.3), (5, 8,  548.00, 5, 4.7),
-- Product 9  Sanitizer
(2, 9,  132.00, 6, 4.2), (3, 9,  138.00, 2, 4.0), (4, 9,  130.00, 4, 3.6),
-- Product 10 Floor cleaner
(3,10,  380.00, 2, 4.0), (4,10,  365.00, 4, 3.5),
-- Product 11 Wipes
(4,11,  180.00, 4, 3.5), (5,11,  188.00, 5, 4.7),
-- Product 12 Coffee
(4,12,  335.00, 4, 3.6), (5,12,  350.00, 5, 4.8), (6,12,  330.00, 9, 3.1),
-- Product 13 Tea
(4,13,  152.00, 4, 3.6), (5,13,  160.00, 5, 4.7), (6,13,  150.00, 9, 3.2),
-- Product 14 Water
(4,14,  168.00, 4, 3.5), (5,14,  176.00, 5, 4.6), (6,14,  165.00, 9, 3.0),
-- Product 15 Desk
(3,15, 1880.00, 5, 4.0), (5,15, 1940.00, 8, 4.7),
-- Product 16 Chair
(3,16, 3000.00, 5, 4.1), (5,16, 3120.00, 8, 4.8),
-- Product 17 Goggles
(2,17,  102.00, 6, 4.2), (5,17,  108.00, 5, 4.6),
-- Product 18 Glassware
(2,18, 1280.00, 6, 4.3), (5,18, 1330.00, 5, 4.7);

-- 2.8 Inventory: (warehouse, product, quantity now, reorder level)
INSERT INTO Inventory (warehouse_id, product_id, quantity, reorder_level) VALUES
-- Warehouse 1 : Kanpur Central (stocks everything)
(1, 1,1100,450),(1, 2, 380,450),(1, 3, 900,400),(1, 4, 700,400),(1, 5, 420,200),
(1, 6,  38, 60),(1, 7, 480,200),(1, 8, 210,150),(1, 9, 600,450),(1,10, 340,150),
(1,11, 180,300),(1,12, 350,150),(1,13, 500,350),(1,14, 700,400),(1,15,  90, 40),
(1,16,  22, 30),(1,17, 650,300),(1,18, 120, 50),
-- Warehouse 2 : Delhi North
(2, 1, 520,220),(2, 2, 150,220),(2, 3, 330,200),(2, 4, 450,200),(2, 6,  55, 30),
(2, 8, 140, 80),(2, 9, 400,220),(2,10, 160, 80),(2,12, 220, 80),(2,14, 450,200),
(2,15,  36, 20),(2,17, 400,150),
-- Warehouse 3 : Lucknow Depot
(3, 1, 120,220),(3, 2, 300,220),(3, 3, 260,200),(3, 4, 190,200),(3, 5, 140,100),
(3,10,  95, 80),(3,11, 240,150),(3,15,  28, 20),(3,17, 210,150),(3,18,  40, 25),
-- Warehouse 4 : Mumbai West
(4, 1, 360,220),(4, 2, 260,220),(4, 3, 120,200),(4, 6,  45, 30),(4, 7, 160,100),
(4, 8,  70, 80),(4, 9, 300,220),(4,10, 130, 80),(4,13, 260,200),(4,17, 180,150),
(4,18,  33, 25);

-- 2.9 Batches for perishable products (batch totals = inventory quantity)
INSERT INTO Inventory_Batches (warehouse_id, product_id, batch_no, quantity, expiry_date) VALUES
(1, 9, 'HS-2406-A', 200, '2026-11-25'), (1, 9, 'HS-2409-B', 400, '2027-09-30'),
(1,12, 'CF-2501-A', 100, '2026-12-05'), (1,12, 'CF-2509-B', 250, '2027-08-31'),
(1,13, 'TB-2505-A', 120, '2026-11-05'), (1,13, 'TB-2509-B', 380, '2027-06-30'),
(1,14, 'WT-2507-A', 300, '2026-12-20'), (1,14, 'WT-2510-B', 400, '2027-04-30'),
(1,11, 'WP-2506-A',  80, '2026-11-18'), (1,11, 'WP-2509-B', 100, '2027-05-31'),
(2, 9, 'HS-2407-A', 150, '2026-11-30'), (2, 9, 'HS-2410-B', 250, '2027-10-31'),
(2,12, 'CF-2510-A', 220, '2027-02-28'),
(2,14, 'WT-2508-A', 250, '2026-12-28'), (2,14, 'WT-2510-B', 200, '2027-05-31'),
(3,11, 'WP-2507-A', 240, '2026-11-14'),
(4, 9, 'HS-2411-A', 300, '2027-08-31'),
(4,13, 'TB-2508-A', 260, '2027-01-31');

-- 2.10 Purchase orders  (orders 1-14 delivered, 15-20 open, 21 cancelled)
INSERT INTO Purchase_Orders (order_id, supplier_id, warehouse_id, order_date, expected_delivery_date, status) VALUES
( 1, 1, 1, '2026-08-10', '2026-08-14', 'Delivered'),
( 2, 3, 3, '2026-08-14', '2026-08-17', 'Delivered'),
( 3, 5, 2, '2026-08-20', '2026-08-27', 'Delivered'),
( 4, 2, 2, '2026-08-25', '2026-09-02', 'Delivered'),
( 5, 4, 1, '2026-09-01', '2026-09-06', 'Delivered'),
( 6, 1, 3, '2026-09-05', '2026-09-09', 'Delivered'),
( 7, 5, 1, '2026-09-12', '2026-09-18', 'Delivered'),
( 8, 3, 3, '2026-09-15', '2026-09-18', 'Delivered'),
( 9, 2, 1, '2026-09-22', '2026-09-30', 'Delivered'),
(10, 4, 1, '2026-09-28', '2026-10-03', 'Delivered'),
(11, 1, 1, '2026-10-02', '2026-10-06', 'Delivered'),
(12, 5, 4, '2026-10-08', '2026-10-14', 'Delivered'),
(13, 3, 2, '2026-10-10', '2026-10-13', 'Delivered'),
(14, 6, 1, '2026-10-12', '2026-10-22', 'Delivered'),
(15, 1, 4, '2026-10-28', '2026-11-02', 'Shipped'),
(16, 5, 1, '2026-10-30', '2026-11-06', 'Shipped'),
(17, 2, 2, '2026-11-01', '2026-11-12', 'Shipped'),
(18, 4, 1, '2026-11-04', '2026-11-11', 'Approved'),
(19, 3, 2, '2026-11-07', '2026-11-12', 'Placed'),
(20, 5, 2, '2026-11-09', '2026-11-16', 'Placed'),
(21, 1, 3, '2026-09-20', '2026-09-25', 'Cancelled');

-- 2.11 Order items.
--  We load (order, product, quantity) into a TEMPORARY staging table and then
--  copy into Order_Items, looking up the unit price from Supplier_Products.
--  The INNER JOIN also guarantees that the supplier really sells the product.
CREATE TEMPORARY TABLE tmp_items (
    order_id INT, product_id INT, quantity INT
);
INSERT INTO tmp_items (order_id, product_id, quantity) VALUES
( 1, 1, 800),( 1, 2,1500),( 1, 3, 300),
( 2, 1, 500),( 2, 4, 200),( 2, 5,  60),
( 3,12, 300),( 3,14, 500),( 3,15,  20),
( 4, 6,  40),( 4, 8, 100),( 4,17, 300),
( 5,10,  60),( 5,11, 150),( 5, 9, 200),
( 6, 1, 600),( 6, 3, 200),( 6, 4, 150),
( 7, 6,  30),( 7,16,  25),( 7,15,  40),
( 8, 2, 800),( 8, 3, 250),
( 9, 6,  35),( 9, 7, 150),
(10,12, 200),(10,14, 400),
(11, 1,1000),(11, 2,1200),(11, 5, 100),
(12,13, 300),(12,18,  30),(12, 8,  50),
(13, 9, 250),(13,10,  70),
(14,13, 300),(14,14, 300),
(15, 1, 700),(15, 3, 250),
(16, 8,  60),(16,13, 350),(16,14, 400),(16,16, 30),
(17, 6,  25),(17, 8,  60),
(18, 9, 300),(18,11, 200),
(19,10,  50),(19,15,  30),(19, 9, 100),
(20,12, 200),(20, 8,  40),
(21, 1, 300);

INSERT INTO Order_Items (order_id, product_id, quantity, unit_price, received_quantity)
SELECT t.order_id,
       t.product_id,
       t.quantity,
       sp.unit_price,
       CASE WHEN po.status = 'Delivered' THEN t.quantity ELSE 0 END   -- delivered orders fully received
FROM tmp_items AS t
INNER JOIN Purchase_Orders   AS po ON po.order_id = t.order_id
INNER JOIN Supplier_Products AS sp ON sp.supplier_id = po.supplier_id
                                  AND sp.product_id  = t.product_id;
DROP TEMPORARY TABLE tmp_items;

-- One short shipment: order 9 asked for 150 USB drives but only 140 arrived.
UPDATE Order_Items SET received_quantity = 140 WHERE order_id = 9 AND product_id = 7;

-- 2.12 Logistics (one shipment per order that has left the supplier)
INSERT INTO Logistics (shipment_id, order_id, method_id, distance_km, transport_cost, dispatch_date, delivery_date, status) VALUES
( 1,  1, 1,  480,  9600.00, '2026-08-11', '2026-08-13', 'Delivered'),
( 2,  2, 4,   85,  1190.00, '2026-08-15', '2026-08-17', 'Delivered'),
( 3,  3, 2, 1470, 13230.00, '2026-08-22', '2026-08-30', 'Delivered'),
( 4,  4, 1, 1400, 26600.00, '2026-08-27', '2026-09-01', 'Delivered'),
( 5,  5, 4,   85,  1105.00, '2026-09-07', '2026-09-09', 'Delivered'),
( 6,  6, 1,  530, 10600.00, '2026-09-06', '2026-09-09', 'Delivered'),
( 7,  7, 2, 1000,  9000.00, '2026-09-13', '2026-09-17', 'Delivered'),
( 8,  8, 4,   85,  1190.00, '2026-09-16', '2026-09-18', 'Delivered'),
( 9,  9, 3, 1250, 81250.00, '2026-10-02', '2026-10-03', 'Delivered'),
(10, 10, 4,   85,  1105.00, '2026-10-05', '2026-10-06', 'Delivered'),
(11, 11, 1,  480, 10080.00, '2026-10-03', '2026-10-05', 'Delivered'),
(12, 12, 2, 1960, 17640.00, '2026-10-09', '2026-10-14', 'Delivered'),
(13, 13, 1,  480,  9600.00, '2026-10-11', '2026-10-12', 'Delivered'),
(14, 14, 2, 2100, 17850.00, '2026-10-21', '2026-10-27', 'Delivered'),
(15, 15, 2, 1400, 12600.00, '2026-10-30', NULL,         'In Transit'),
(16, 16, 2, 1000,  9000.00, '2026-11-01', NULL,         'In Transit'),
(17, 17, 1, 1400, 26600.00, '2026-11-03', NULL,         'In Transit');

-- 2.13 Stock movements ------------------------------------------------
-- (a) IN movements: goods received from every delivered purchase order
INSERT INTO Stock_Movements (warehouse_id, product_id, movement_type, quantity, movement_date, order_id, remarks)
SELECT po.warehouse_id, oi.product_id, 'IN', oi.received_quantity, l.delivery_date,
       po.order_id, CONCAT('Received PO #', po.order_id)
FROM Purchase_Orders po
INNER JOIN Order_Items oi ON oi.order_id = po.order_id
INNER JOIN Logistics   l  ON l.order_id  = po.order_id
WHERE po.status = 'Delivered' AND oi.received_quantity > 0;

-- (b) OUT movements: 90 days of customer sales for every inventory line.
--     A recursive CTE produces the day numbers 1..90. Daily quantity depends on
--     product price band (cheap items sell more), the warehouse (Kanpur is the
--     busiest) and a repeating 1-5 pattern so the data looks "natural".
INSERT INTO Stock_Movements (warehouse_id, product_id, movement_type, quantity, movement_date, customer_id, remarks)
WITH RECURSIVE days (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM days WHERE n < 90
)
SELECT i.warehouse_id,
       i.product_id,
       'OUT',
       (CASE WHEN p.price < 300 THEN 6 WHEN p.price < 1000 THEN 3 ELSE 1 END)
         * (CASE WHEN i.warehouse_id = 1 THEN 2 ELSE 1 END)
         * (1 + MOD(i.product_id * 3 + i.warehouse_id * 5 + d.n * 7, 5)),
       DATE_SUB(fn_today(), INTERVAL d.n DAY),
       1 + MOD(d.n * 3 + i.product_id + i.warehouse_id, 12),
       'Customer sale'
FROM Inventory i
INNER JOIN Products p ON p.product_id = i.product_id
CROSS JOIN days d;

-- (c) Opening balance: the stock that must have been on the shelf on 1-Aug-2026
--     so that  opening + IN - OUT  =  today's Inventory.quantity.
INSERT INTO Stock_Movements (warehouse_id, product_id, movement_type, quantity, movement_date, remarks)
SELECT i.warehouse_id, i.product_id, 'IN',
       i.quantity + COALESCE(m.out_qty, 0) - COALESCE(m.in_qty, 0),
       '2026-08-01',
       'Opening balance'
FROM Inventory i
LEFT JOIN (
    SELECT warehouse_id, product_id,
           SUM(CASE WHEN movement_type = 'OUT' THEN quantity ELSE 0 END) AS out_qty,
           SUM(CASE WHEN movement_type = 'IN'  THEN quantity ELSE 0 END) AS in_qty
    FROM Stock_Movements
    GROUP BY warehouse_id, product_id
) m ON m.warehouse_id = i.warehouse_id AND m.product_id = i.product_id;


/* =====================================================================
   PART 3 : DATA VERIFICATION
   ===================================================================== */
SELECT '### CHECK 1: row count of every table' AS section;
SELECT 'Suppliers' AS table_name, COUNT(*) AS row_count FROM Suppliers
UNION ALL SELECT 'Manufacturers',     COUNT(*) FROM Manufacturers
UNION ALL SELECT 'Products',          COUNT(*) FROM Products
UNION ALL SELECT 'Warehouses',        COUNT(*) FROM Warehouses
UNION ALL SELECT 'Customers',         COUNT(*) FROM Customers
UNION ALL SELECT 'Transport_Methods', COUNT(*) FROM Transport_Methods
UNION ALL SELECT 'Supplier_Products', COUNT(*) FROM Supplier_Products
UNION ALL SELECT 'Inventory',         COUNT(*) FROM Inventory
UNION ALL SELECT 'Inventory_Batches', COUNT(*) FROM Inventory_Batches
UNION ALL SELECT 'Purchase_Orders',   COUNT(*) FROM Purchase_Orders
UNION ALL SELECT 'Order_Items',       COUNT(*) FROM Order_Items
UNION ALL SELECT 'Logistics',         COUNT(*) FROM Logistics
UNION ALL SELECT 'Stock_Movements',   COUNT(*) FROM Stock_Movements;

SELECT '### CHECK 2: ledger vs inventory (expect 0 rows = perfectly reconciled)' AS section;
SELECT i.inventory_id, i.warehouse_id, i.product_id, i.quantity AS inventory_qty, l.ledger_qty
FROM Inventory i
LEFT JOIN (
    SELECT warehouse_id, product_id,
           SUM(CASE WHEN movement_type = 'IN' THEN quantity ELSE -quantity END) AS ledger_qty
    FROM Stock_Movements
    GROUP BY warehouse_id, product_id
) l ON l.warehouse_id = i.warehouse_id AND l.product_id = i.product_id
WHERE i.quantity <> COALESCE(l.ledger_qty, 0);

SELECT '### CHECK 3: batch totals vs inventory for perishables (expect 0 rows)' AS section;
SELECT i.warehouse_id, i.product_id, i.quantity AS inventory_qty, SUM(b.quantity) AS batch_total
FROM Inventory i
INNER JOIN Products p ON p.product_id = i.product_id AND p.is_perishable = 1
LEFT JOIN Inventory_Batches b ON b.warehouse_id = i.warehouse_id AND b.product_id = i.product_id
GROUP BY i.warehouse_id, i.product_id, i.quantity
HAVING i.quantity <> COALESCE(SUM(b.quantity), 0);

SELECT '### CHECK 4: warehouses over capacity (expect 0 rows)' AS section;
SELECT w.name, w.capacity, SUM(i.quantity) AS units_stored
FROM Warehouses w
INNER JOIN Inventory i ON i.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.name, w.capacity
HAVING SUM(i.quantity) > w.capacity;


/* =====================================================================
   PART 4 : VIEWS  (a view = a saved SELECT you can query like a table)
   ===================================================================== */

-- 4.1 Products below reorder level
CREATE OR REPLACE VIEW v_low_stock AS
SELECT i.inventory_id, w.warehouse_id, w.name AS warehouse,
       p.product_id, p.product_name,
       i.quantity AS current_stock, i.reorder_level,
       i.reorder_level - i.quantity AS shortfall
FROM Inventory i
INNER JOIN Warehouses w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products   p ON p.product_id   = i.product_id
WHERE i.quantity < i.reorder_level;

-- 4.2 Supplier ranking per product (price 40% + delivery speed 30% + quality 30%)
--     Score = 100 * ( 0.40 * best_price / price
--                   + 0.30 * fastest_lead / lead_time
--                   + 0.30 * quality / 5 )
--     The cheapest AND fastest AND best-quality supplier would score 100.
--     Only ACTIVE suppliers are ranked.
CREATE OR REPLACE VIEW v_supplier_ranking AS
WITH base AS (
    SELECT sp.product_id, sp.supplier_id, sp.unit_price, sp.lead_time_days, sp.quality_score,
           MIN(sp.unit_price)     OVER (PARTITION BY sp.product_id) AS best_price,
           MIN(sp.lead_time_days) OVER (PARTITION BY sp.product_id) AS best_lead
    FROM Supplier_Products sp
    INNER JOIN Suppliers s ON s.supplier_id = sp.supplier_id
    WHERE s.is_active = 1
),
scored AS (
    SELECT product_id, supplier_id, unit_price, lead_time_days, quality_score,
           ROUND(100 * ( 0.40 * best_price / unit_price
                       + 0.30 * best_lead  / lead_time_days
                       + 0.30 * quality_score / 5.0 ), 1) AS score
    FROM base
)
SELECT p.product_id, p.product_name, s.supplier_id, s.name AS supplier_name,
       sc.unit_price, sc.lead_time_days, sc.quality_score, sc.score,
       RANK() OVER (PARTITION BY sc.product_id ORDER BY sc.score DESC) AS supplier_rank
FROM scored sc
INNER JOIN Products  p ON p.product_id  = sc.product_id
INNER JOIN Suppliers s ON s.supplier_id = sc.supplier_id;

-- 4.3 Order tracking: placement -> shipment -> delivery
CREATE OR REPLACE VIEW v_order_tracking AS
SELECT po.order_id, s.name AS supplier, w.name AS warehouse,
       po.order_date, po.expected_delivery_date,
       po.status AS order_status,
       COALESCE(l.status, 'Not dispatched') AS shipment_status,
       tm.method_name, l.dispatch_date, l.delivery_date,
       CASE
         WHEN po.status = 'Cancelled' THEN 'Cancelled'
         WHEN po.status = 'Delivered' AND l.delivery_date <= po.expected_delivery_date
              THEN 'Delivered on time'
         WHEN po.status = 'Delivered'
              THEN CONCAT('Delivered ', DATEDIFF(l.delivery_date, po.expected_delivery_date), ' day(s) late')
         WHEN po.expected_delivery_date < fn_today()
              THEN CONCAT('OVERDUE by ', DATEDIFF(fn_today(), po.expected_delivery_date), ' day(s)')
         ELSE 'On schedule'
       END AS tracking_status
FROM Purchase_Orders po
INNER JOIN Suppliers  s ON s.supplier_id  = po.supplier_id
INNER JOIN Warehouses w ON w.warehouse_id = po.warehouse_id
LEFT JOIN  Logistics  l ON l.order_id     = po.order_id
LEFT JOIN  Transport_Methods tm ON tm.method_id = l.method_id;

-- 4.4 Expiry alerts for every batch
CREATE OR REPLACE VIEW v_expiry_alerts AS
SELECT b.batch_id, w.name AS warehouse, p.product_name, b.batch_no, b.quantity,
       b.expiry_date,
       DATEDIFF(b.expiry_date, fn_today()) AS days_to_expiry,
       CASE
         WHEN b.expiry_date <  fn_today()                              THEN 'EXPIRED'
         WHEN b.expiry_date <= DATE_ADD(fn_today(), INTERVAL 14 DAY)   THEN 'CRITICAL (<=14 days)'
         WHEN b.expiry_date <= DATE_ADD(fn_today(), INTERVAL 30 DAY)   THEN 'WARNING (<=30 days)'
         WHEN b.expiry_date <= DATE_ADD(fn_today(), INTERVAL 60 DAY)   THEN 'WATCH (<=60 days)'
         ELSE 'OK'
       END AS alert_level,
       b.quantity * p.price AS value_at_risk
FROM Inventory_Batches b
INNER JOIN Warehouses w ON w.warehouse_id = b.warehouse_id
INNER JOIN Products   p ON p.product_id   = b.product_id;

-- 4.5 Stock-out forecast (average of the last 30 days of OUT movements)
CREATE OR REPLACE VIEW v_stock_out_forecast AS
SELECT w.name AS warehouse, p.product_name,
       i.quantity AS current_stock,
       ROUND(s.units_30d / 30, 1) AS avg_daily_sales,
       ROUND(i.quantity / (s.units_30d / 30), 1) AS days_of_stock_left,
       DATE_ADD(fn_today(), INTERVAL FLOOR(i.quantity / (s.units_30d / 30)) DAY) AS predicted_stockout_date,
       CASE
         WHEN i.quantity / (s.units_30d / 30) <=  7 THEN 'CRITICAL'
         WHEN i.quantity / (s.units_30d / 30) <= 14 THEN 'HIGH'
         WHEN i.quantity / (s.units_30d / 30) <= 30 THEN 'MEDIUM'
         ELSE 'OK'
       END AS urgency
FROM Inventory i
INNER JOIN Warehouses w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products   p ON p.product_id   = i.product_id
INNER JOIN (
    SELECT warehouse_id, product_id, SUM(quantity) AS units_30d
    FROM Stock_Movements
    WHERE movement_type = 'OUT'
      AND movement_date BETWEEN DATE_SUB(fn_today(), INTERVAL 30 DAY)
                            AND DATE_SUB(fn_today(), INTERVAL 1 DAY)
    GROUP BY warehouse_id, product_id
) s ON s.warehouse_id = i.warehouse_id AND s.product_id = i.product_id;


/* =====================================================================
   PART 5 : THE 8 BUSINESS QUERIES
   ===================================================================== */

/* ---------------------------------------------------------------------
   QUERY 1 : LOW-STOCK DETECTION
   Purpose : list every warehouse/product where stock < reorder level.
   Logic   : join Inventory to Warehouses and Products for readable names,
             keep rows where quantity < reorder_level, and show how far
             below the line they are (shortfall and % of reorder level).
   --------------------------------------------------------------------- */
SELECT '### Q1: Low-stock detection' AS section;
SELECT w.name                                        AS warehouse,
       p.product_name,
       i.quantity                                    AS current_stock,
       i.reorder_level,
       i.reorder_level - i.quantity                  AS shortfall,
       ROUND(i.quantity * 100.0 / i.reorder_level, 1) AS pct_of_reorder_level
FROM Inventory AS i
INNER JOIN Warehouses AS w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products   AS p ON p.product_id   = i.product_id
WHERE i.quantity < i.reorder_level
ORDER BY pct_of_reorder_level ASC, w.name;

-- Q1B : the same idea at product level, using GROUP BY ... HAVING
--       "Which products are short in AT LEAST ONE warehouse?"
SELECT '### Q1B: Products short in at least one warehouse (GROUP BY + HAVING)' AS section;
SELECT p.product_name,
       COUNT(*)                          AS warehouses_stocking,
       SUM(i.quantity < i.reorder_level) AS warehouses_below_reorder,
       SUM(i.quantity)                   AS total_stock_all_warehouses
FROM Inventory AS i
INNER JOIN Products AS p ON p.product_id = i.product_id
GROUP BY p.product_id, p.product_name
HAVING SUM(i.quantity < i.reorder_level) >= 1
ORDER BY warehouses_below_reorder DESC, p.product_name;

/* ---------------------------------------------------------------------
   QUERY 2 : BEST SUPPLIER IDENTIFICATION
   Purpose : for every product, find the supplier with the best balance of
             price, delivery time and quality.
   Logic   : (1) for each product find the lowest price and fastest lead
             time using window functions MIN() OVER (PARTITION BY product);
             (2) turn each supplier's numbers into a 0-100 score
                 (40% price, 30% speed, 30% quality);
             (3) RANK() suppliers inside each product and keep rank 1.
             Inactive suppliers are ignored.
   --------------------------------------------------------------------- */
SELECT '### Q2: Best supplier per product' AS section;
WITH base AS (
    SELECT sp.product_id, sp.supplier_id, sp.unit_price, sp.lead_time_days, sp.quality_score,
           MIN(sp.unit_price)     OVER (PARTITION BY sp.product_id) AS best_price,
           MIN(sp.lead_time_days) OVER (PARTITION BY sp.product_id) AS best_lead
    FROM Supplier_Products sp
    INNER JOIN Suppliers s ON s.supplier_id = sp.supplier_id
    WHERE s.is_active = 1
),
scored AS (
    SELECT product_id, supplier_id, unit_price, lead_time_days, quality_score,
           ROUND(100 * ( 0.40 * best_price / unit_price
                       + 0.30 * best_lead  / lead_time_days
                       + 0.30 * quality_score / 5.0 ), 1) AS score
    FROM base
),
ranked AS (
    SELECT scored.*,
           RANK() OVER (PARTITION BY product_id ORDER BY score DESC) AS supplier_rank
    FROM scored
)
SELECT p.product_name,
       s.name AS best_supplier,
       r.unit_price, r.lead_time_days, r.quality_score, r.score
FROM ranked r
INNER JOIN Products  p ON p.product_id  = r.product_id
INNER JOIN Suppliers s ON s.supplier_id = r.supplier_id
WHERE r.supplier_rank = 1
ORDER BY p.product_id;

-- Q2B : overall supplier leaderboard (average score across all products they quote)
SELECT '### Q2B: Overall supplier leaderboard' AS section;
SELECT DENSE_RANK() OVER (ORDER BY AVG(score) DESC) AS overall_rank,
       supplier_name,
       COUNT(*)              AS products_quoted,
       ROUND(AVG(score), 1)  AS avg_score,
       SUM(supplier_rank = 1) AS products_where_best
FROM v_supplier_ranking
GROUP BY supplier_id, supplier_name
ORDER BY overall_rank;

/* ---------------------------------------------------------------------
   QUERY 3 : STOCK-OUT PREDICTION
   Purpose : estimate when each product will run out.
   Logic   : average daily sales = total OUT quantity of the last 30 days / 30
             days of stock left  = current stock / average daily sales
             predicted date      = today + days left
             Only items with 14 days of cover or less are shown.
   --------------------------------------------------------------------- */
SELECT '### Q3: Stock-out prediction (<= 14 days of cover)' AS section;
WITH daily_sales AS (
    SELECT warehouse_id, product_id,
           SUM(quantity) / 30 AS avg_daily_sales
    FROM Stock_Movements
    WHERE movement_type = 'OUT'
      AND movement_date BETWEEN DATE_SUB(fn_today(), INTERVAL 30 DAY)
                            AND DATE_SUB(fn_today(), INTERVAL 1 DAY)
    GROUP BY warehouse_id, product_id
)
SELECT w.name AS warehouse,
       p.product_name,
       i.quantity                                  AS current_stock,
       ROUND(d.avg_daily_sales, 1)                 AS avg_daily_sales,
       ROUND(i.quantity / d.avg_daily_sales, 1)    AS days_left,
       DATE_ADD(fn_today(), INTERVAL FLOOR(i.quantity / d.avg_daily_sales) DAY) AS predicted_stockout_date
FROM Inventory i
INNER JOIN daily_sales d ON d.warehouse_id = i.warehouse_id AND d.product_id = i.product_id
INNER JOIN Warehouses  w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products    p ON p.product_id   = i.product_id
WHERE i.quantity / d.avg_daily_sales <= 14
ORDER BY days_left, w.name;

/* ---------------------------------------------------------------------
   QUERY 4 : PENDING ORDERS
   Purpose : purchase orders that have not been delivered yet.
   Logic   : keep status Placed / Approved / Shipped (not Delivered or
             Cancelled). LEFT JOIN Logistics because orders that have not
             been dispatched have no shipment row. Add up the lines for
             units still due and order value; compute days overdue.
   --------------------------------------------------------------------- */
SELECT '### Q4: Pending purchase orders' AS section;
SELECT po.order_id,
       s.name                                         AS supplier,
       w.name                                         AS destination,
       po.order_date,
       po.expected_delivery_date                      AS expected_by,
       po.status,
       COALESCE(l.status, 'Not dispatched')           AS shipment_status,
       SUM(oi.quantity - oi.received_quantity)        AS units_pending,
       SUM(oi.quantity * oi.unit_price)               AS order_value_inr,
       GREATEST(DATEDIFF(fn_today(), po.expected_delivery_date), 0) AS days_overdue
FROM Purchase_Orders po
INNER JOIN Suppliers  s  ON s.supplier_id  = po.supplier_id
INNER JOIN Warehouses w  ON w.warehouse_id = po.warehouse_id
INNER JOIN Order_Items oi ON oi.order_id   = po.order_id
LEFT JOIN  Logistics  l  ON l.order_id     = po.order_id
WHERE po.status IN ('Placed', 'Approved', 'Shipped')
GROUP BY po.order_id, s.name, w.name, po.order_date, po.expected_delivery_date, po.status, l.status
ORDER BY days_overdue DESC, po.expected_delivery_date;

/* ---------------------------------------------------------------------
   QUERY 5 : SUPPLIER PERFORMANCE (on-time delivery %)
   Purpose : what share of each supplier's delivered orders arrived on or
             before the promised date?
   Logic   : LEFT JOIN from Suppliers so that suppliers with no deliveries
             would still appear. A delivery is "on time" when the actual
             delivery_date (Logistics) <= expected_delivery_date (order).
             CASE WHEN turns each order into 1 (on time) or 0 (late);
             the average of those = on-time percentage.
   --------------------------------------------------------------------- */
SELECT '### Q5: Supplier on-time delivery performance' AS section;
SELECT s.name AS supplier,
       COUNT(po.order_id)                                                     AS delivered_orders,
       SUM(CASE WHEN l.delivery_date <= po.expected_delivery_date THEN 1 ELSE 0 END) AS on_time_orders,
       ROUND(100.0 * SUM(CASE WHEN l.delivery_date <= po.expected_delivery_date THEN 1 ELSE 0 END)
             / NULLIF(COUNT(po.order_id), 0), 1)                              AS on_time_pct,
       ROUND(AVG(DATEDIFF(l.delivery_date, po.expected_delivery_date)), 1)    AS avg_days_vs_promise
FROM Suppliers s
LEFT JOIN Purchase_Orders po ON po.supplier_id = s.supplier_id AND po.status = 'Delivered'
LEFT JOIN Logistics       l  ON l.order_id     = po.order_id
GROUP BY s.supplier_id, s.name
ORDER BY on_time_pct DESC, delivered_orders DESC;

/* ---------------------------------------------------------------------
   QUERY 6 : WAREHOUSE COMPARISON
   Purpose : which warehouse holds the most / least stock?
   Logic   : total units, product lines, stock value and capacity use per
             warehouse; RANK() window functions pick the highest and
             the lowest.
   --------------------------------------------------------------------- */
SELECT '### Q6: Warehouse comparison' AS section;
WITH wh AS (
    SELECT w.warehouse_id, w.name, w.capacity,
           SUM(i.quantity)            AS total_units,
           COUNT(i.product_id)        AS product_lines,
           SUM(i.quantity * p.price)  AS stock_value_inr
    FROM Warehouses w
    LEFT JOIN Inventory i ON i.warehouse_id = w.warehouse_id
    LEFT JOIN Products  p ON p.product_id   = i.product_id
    GROUP BY w.warehouse_id, w.name, w.capacity
),
ranked AS (
    SELECT wh.*,
           RANK() OVER (ORDER BY total_units DESC) AS rank_high,
           RANK() OVER (ORDER BY total_units ASC)  AS rank_low
    FROM wh
)
SELECT name AS warehouse, total_units, product_lines,
       stock_value_inr,
       ROUND(100.0 * total_units / capacity, 1) AS capacity_used_pct,
       CASE WHEN rank_high = 1 THEN 'HIGHEST'
            WHEN rank_low  = 1 THEN 'LOWEST'
            ELSE '-' END AS flag
FROM ranked
ORDER BY total_units DESC;

/* ---------------------------------------------------------------------
   QUERY 7 : REPLENISHMENT TRACKING
   Purpose : quantities already ordered but not yet received, compared
             with what each warehouse needs.
   Logic   : a CTE adds up (quantity - received_quantity) of all open
             orders per warehouse+product. LEFT JOIN it to Inventory:
             projected stock = on hand + on order. The CASE labels whether
             the open orders fix a shortage.
   --------------------------------------------------------------------- */
SELECT '### Q7: Replenishment tracking' AS section;
WITH on_order AS (
    SELECT po.warehouse_id, oi.product_id,
           SUM(oi.quantity - oi.received_quantity) AS qty_on_order
    FROM Purchase_Orders po
    INNER JOIN Order_Items oi ON oi.order_id = po.order_id
    WHERE po.status IN ('Placed', 'Approved', 'Shipped')
    GROUP BY po.warehouse_id, oi.product_id
)
SELECT w.name AS warehouse,
       p.product_name,
       i.quantity                          AS on_hand,
       i.reorder_level,
       COALESCE(oo.qty_on_order, 0)        AS qty_on_order,
       i.quantity + COALESCE(oo.qty_on_order, 0) AS projected_stock,
       CASE
         WHEN i.quantity < i.reorder_level AND COALESCE(oo.qty_on_order, 0) = 0
              THEN 'ACTION: low and nothing on order'
         WHEN i.quantity < i.reorder_level
              AND i.quantity + oo.qty_on_order >= i.reorder_level
              THEN 'Covered by open order'
         WHEN i.quantity < i.reorder_level
              THEN 'Order too small - top up'
         ELSE 'Healthy - routine replenishment'
       END AS replenishment_status
FROM Inventory i
INNER JOIN Warehouses w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products   p ON p.product_id   = i.product_id
LEFT JOIN  on_order  oo ON oo.warehouse_id = i.warehouse_id AND oo.product_id = i.product_id
WHERE i.quantity < i.reorder_level OR oo.qty_on_order IS NOT NULL
ORDER BY replenishment_status, w.name, p.product_name;

/* ---------------------------------------------------------------------
   QUERY 8 : TRANSPORTATION ANALYSIS (delivery optimisation)
   Purpose : which transport method is the most cost-effective, and what
             do you give up in speed?
   Logic   : for delivered shipments compute cost per km, cost per unit
             carried and transit days (dispatch -> delivery), average them
             per method and rank the methods by cost and by speed.
   --------------------------------------------------------------------- */
SELECT '### Q8: Transportation analysis' AS section;
WITH order_units AS (
    SELECT order_id, SUM(quantity) AS units FROM Order_Items GROUP BY order_id
)
SELECT tm.method_name,
       COUNT(*)                                              AS shipments,
       ROUND(AVG(l.transport_cost / l.distance_km), 2)       AS avg_cost_per_km,
       ROUND(AVG(l.transport_cost / ou.units), 2)            AS avg_cost_per_unit,
       ROUND(AVG(DATEDIFF(l.delivery_date, l.dispatch_date)), 1) AS avg_transit_days,
       RANK() OVER (ORDER BY AVG(l.transport_cost / l.distance_km))              AS cost_rank,
       RANK() OVER (ORDER BY AVG(DATEDIFF(l.delivery_date, l.dispatch_date)))    AS speed_rank
FROM Logistics l
INNER JOIN Transport_Methods tm ON tm.method_id = l.method_id
INNER JOIN order_units       ou ON ou.order_id  = l.order_id
WHERE l.status = 'Delivered'
GROUP BY tm.method_id, tm.method_name
ORDER BY cost_rank;


/* =====================================================================
   PART 6 : EXTRA FEATURE QUERIES
   ===================================================================== */

/* ---- FEATURE: EXPIRY TRACKING ---------------------------------------
   Flags batches that are expired or expire within 60 days (view 4.4).  */
SELECT '### F1: Expiry tracking' AS section;
SELECT warehouse, product_name, batch_no, quantity, expiry_date,
       days_to_expiry, alert_level, value_at_risk
FROM v_expiry_alerts
WHERE alert_level <> 'OK'
ORDER BY days_to_expiry;

/* ---- FEATURE: BACKUP SUPPLIERS --------------------------------------
   F2: primary (rank 1) and first backup (rank 2) supplier per product.
       Self-join of the ranking view with itself.                       */
SELECT '### F2: Primary and backup supplier per product' AS section;
SELECT r1.product_name,
       r1.supplier_name AS primary_supplier,
       r1.unit_price    AS primary_price,
       r2.supplier_name AS backup_supplier,
       r2.unit_price    AS backup_price,
       r2.lead_time_days AS backup_lead_days,
       ROUND(100.0 * (r2.unit_price - r1.unit_price) / r1.unit_price, 1) AS backup_price_diff_pct
FROM v_supplier_ranking r1
LEFT JOIN v_supplier_ranking r2
       ON r2.product_id = r1.product_id AND r2.supplier_rank = 2
WHERE r1.supplier_rank = 1
ORDER BY r1.product_name;

/*  F3: "What if the supplier of an open order cannot deliver?"
        For each line of every open order, find the best ACTIVE alternative
        supplier. The correlated subquery looks up the best rank among all
        suppliers except the one already on the order.                   */
SELECT '### F3: Backup supplier for each line of an open order' AS section;
SELECT oi.order_id,
       s.name         AS current_supplier,
       p.product_name,
       oi.unit_price  AS current_price,
       alt.supplier_name AS backup_supplier,
       alt.unit_price    AS backup_price,
       alt.lead_time_days AS backup_lead_days
FROM Purchase_Orders po
INNER JOIN Suppliers   s  ON s.supplier_id = po.supplier_id
INNER JOIN Order_Items oi ON oi.order_id   = po.order_id
INNER JOIN Products    p  ON p.product_id  = oi.product_id
INNER JOIN v_supplier_ranking alt
        ON alt.product_id = oi.product_id
       AND alt.supplier_id <> po.supplier_id
       AND alt.supplier_rank = (
             SELECT MIN(r.supplier_rank)
             FROM v_supplier_ranking r
             WHERE r.product_id  = oi.product_id
               AND r.supplier_id <> po.supplier_id)
WHERE po.status IN ('Placed', 'Approved', 'Shipped')
ORDER BY oi.order_id, p.product_name;

/* ---- FEATURE: ORDER TRACKING ----------------------------------------
   Full life-cycle status of the most recent orders (view 4.3).         */
SELECT '### F4: Order tracking (latest 10 orders)' AS section;
SELECT order_id, supplier, warehouse, order_date, expected_delivery_date,
       order_status, shipment_status, method_name, delivery_date, tracking_status
FROM v_order_tracking
ORDER BY order_id DESC
LIMIT 10;

/* ---- FEATURE: LOW-STOCK ALERT using view + stock-out forecast -------- */
SELECT '### F5: Stock-out forecast view - CRITICAL and HIGH urgency' AS section;
SELECT * FROM v_stock_out_forecast
WHERE urgency IN ('CRITICAL', 'HIGH')
ORDER BY days_of_stock_left, warehouse;


/* =====================================================================
   PART 7 : JOINS, SUBQUERIES & WINDOW FUNCTIONS SHOWCASE
   ===================================================================== */

-- 7.1 INNER JOIN + GROUP BY : stock value by category and warehouse
SELECT '### S1: INNER JOIN + GROUP BY - stock value per category' AS section;
SELECT p.category,
       SUM(i.quantity)           AS units,
       SUM(i.quantity * p.price) AS stock_value_inr
FROM Inventory i
INNER JOIN Products p ON p.product_id = i.product_id
GROUP BY p.category
ORDER BY stock_value_inr DESC;

-- 7.2 RIGHT JOIN : every manufacturer, even one with no products yet
SELECT '### S2: RIGHT JOIN - products per manufacturer' AS section;
SELECT m.name AS manufacturer, m.location, COUNT(p.product_id) AS products_made
FROM Products p
RIGHT JOIN Manufacturers m ON m.manufacturer_id = p.manufacturer_id
GROUP BY m.manufacturer_id, m.name, m.location
ORDER BY products_made DESC, m.name;

-- 7.3 CROSS JOIN + LEFT JOIN (anti-join) : products a warehouse does NOT stock
SELECT '### S3: CROSS JOIN + LEFT JOIN - stocking gaps per warehouse' AS section;
SELECT w.name AS warehouse,
       COUNT(*) AS products_not_stocked
FROM Warehouses w
CROSS JOIN Products p
LEFT JOIN Inventory i ON i.warehouse_id = w.warehouse_id AND i.product_id = p.product_id
WHERE i.inventory_id IS NULL
GROUP BY w.warehouse_id, w.name
ORDER BY products_not_stocked DESC;

-- 7.4 NESTED subquery : products offered by at least one supplier rated 4.5 or more
SELECT '### S4: Nested subquery - products offered by top-rated suppliers' AS section;
SELECT product_name, category
FROM Products
WHERE product_id IN (
        SELECT product_id
        FROM Supplier_Products
        WHERE supplier_id IN (SELECT supplier_id FROM Suppliers WHERE rating >= 4.5)
      )
ORDER BY product_name;

-- 7.5 CORRELATED subquery : stock lines below the product's average across warehouses
--     (the inner query is re-evaluated for every outer row)
SELECT '### S5: Correlated subquery - stock below the product average' AS section;
SELECT w.name AS warehouse, p.product_name, i.quantity,
       (SELECT ROUND(AVG(i2.quantity), 0)
        FROM Inventory i2
        WHERE i2.product_id = i.product_id) AS avg_across_warehouses
FROM Inventory i
INNER JOIN Warehouses w ON w.warehouse_id = i.warehouse_id
INNER JOIN Products   p ON p.product_id   = i.product_id
WHERE i.quantity < (SELECT AVG(i2.quantity)
                    FROM Inventory i2
                    WHERE i2.product_id = i.product_id)
  AND i.product_id IN (1, 2, 3)
ORDER BY p.product_name, i.quantity;

-- 7.6 EXISTS : suppliers that have delivered at least one order late
SELECT '### S6: EXISTS - suppliers with at least one late delivery' AS section;
SELECT s.name
FROM Suppliers s
WHERE EXISTS (
        SELECT 1
        FROM Purchase_Orders po
        INNER JOIN Logistics l ON l.order_id = po.order_id
        WHERE po.supplier_id = s.supplier_id
          AND po.status = 'Delivered'
          AND l.delivery_date > po.expected_delivery_date)
ORDER BY s.name;

-- 7.7 WINDOW FUNCTION : top 3 selling products per warehouse (last 30 days)
SELECT '### S7: RANK() window - top 3 sellers per warehouse' AS section;
WITH sales AS (
    SELECT sm.warehouse_id, sm.product_id, SUM(sm.quantity) AS units_sold
    FROM Stock_Movements sm
    WHERE sm.movement_type = 'OUT'
      AND sm.movement_date BETWEEN DATE_SUB(fn_today(), INTERVAL 30 DAY)
                               AND DATE_SUB(fn_today(), INTERVAL 1 DAY)
    GROUP BY sm.warehouse_id, sm.product_id
),
ranked AS (
    SELECT s.*, RANK() OVER (PARTITION BY s.warehouse_id ORDER BY s.units_sold DESC) AS rnk
    FROM sales s
)
SELECT w.name AS warehouse, p.product_name, r.units_sold, r.rnk AS rank_in_warehouse
FROM ranked r
INNER JOIN Warehouses w ON w.warehouse_id = r.warehouse_id
INNER JOIN Products   p ON p.product_id   = r.product_id
WHERE r.rnk <= 3
ORDER BY w.name, r.rnk, p.product_name;

-- 7.8 WINDOW FUNCTION : weekly sales revenue, week-over-week change (LAG)
--     and a 2-week moving average
SELECT '### S8: LAG() and moving average - weekly sales revenue' AS section;
WITH weekly AS (
    SELECT DATE_SUB(sm.movement_date, INTERVAL WEEKDAY(sm.movement_date) DAY) AS week_start,
           SUM(sm.quantity * p.price) AS revenue
    FROM Stock_Movements sm
    INNER JOIN Products p ON p.product_id = sm.product_id
    WHERE sm.movement_type = 'OUT'
      AND sm.movement_date >= DATE_SUB(fn_today(), INTERVAL 28 DAY)
    GROUP BY week_start
)
SELECT week_start,
       revenue,
       LAG(revenue) OVER (ORDER BY week_start) AS previous_week,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY week_start))
             / LAG(revenue) OVER (ORDER BY week_start), 1) AS change_pct,
       ROUND(AVG(revenue) OVER (ORDER BY week_start ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), 0) AS moving_avg_2wk
FROM weekly
ORDER BY week_start;

-- 7.9 WINDOW FUNCTION : running stock balance (ledger) of Toner in Kanpur
SELECT '### S9: Running balance window - Toner, Kanpur warehouse (last 8 movements)' AS section;
SELECT *
FROM (
    SELECT movement_date, movement_type, quantity,
           SUM(CASE WHEN movement_type = 'IN' THEN quantity ELSE -quantity END)
               OVER (ORDER BY movement_date, movement_id) AS running_balance,
           ROW_NUMBER() OVER (ORDER BY movement_date DESC, movement_id DESC) AS recent_n
    FROM Stock_Movements
    WHERE warehouse_id = 1 AND product_id = 6
) t
WHERE recent_n <= 8
ORDER BY movement_date, recent_n DESC;


/* =====================================================================
   PART 8 : INDEXING & QUERY OPTIMISATION WITH EXPLAIN
   =====================================================================
   EXPLAIN shows HOW MySQL runs a query.  Columns to look at:
     type = ALL      -> full table scan (slow on big tables)
     type = range    -> index range scan (fast)
     key             -> the index actually used
     rows            -> estimated rows examined (smaller is better)
   NOTE: literal dates are used below (not fn_today()) because MySQL can only
   pick a range scan when it knows the value while planning the query.      */

SELECT '### E1: EXPLAIN before adding an index' AS section;
EXPLAIN
SELECT product_id, SUM(quantity) AS units_sold
FROM Stock_Movements
WHERE movement_type = 'OUT'
  AND movement_date >= '2026-10-11'
GROUP BY product_id;

-- Composite index: the equality column first, the range column second.
CREATE INDEX idx_sm_type_date ON Stock_Movements (movement_type, movement_date);

-- More useful indexes for the reports above
CREATE INDEX idx_po_status         ON Purchase_Orders (status, expected_delivery_date);
CREATE INDEX idx_batches_expiry    ON Inventory_Batches (expiry_date);
CREATE INDEX idx_sm_wh_prod_date   ON Stock_Movements (warehouse_id, product_id, movement_date);

SELECT '### E2: EXPLAIN after adding the index' AS section;
EXPLAIN
SELECT product_id, SUM(quantity) AS units_sold
FROM Stock_Movements
WHERE movement_type = 'OUT'
  AND movement_date >= '2026-10-11'
GROUP BY product_id;

SELECT '### E3: EXPLAIN for an index-supported join (pending orders)' AS section;
EXPLAIN
SELECT po.order_id, s.name, po.expected_delivery_date
FROM Purchase_Orders po
INNER JOIN Suppliers s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Shipped'
ORDER BY po.expected_delivery_date;

-- List all indexes of one table
SHOW INDEX FROM Stock_Movements;


/* =====================================================================
   PART 9 : INSERT / UPDATE / DELETE OPERATIONS
   ===================================================================== */

-- 9.1 INSERT : add a new product and stock it in the Kanpur warehouse
INSERT INTO Products (product_name, category, price, unit, is_perishable, manufacturer_id)
VALUES ('Wall Clock (Round)', 'Office Supplies', 380.00, 'piece', 0, 3);

INSERT INTO Inventory (warehouse_id, product_id, quantity, reorder_level)
SELECT 1, product_id, 100, 40 FROM Products WHERE product_name = 'Wall Clock (Round)';

SELECT '### D1: INSERT result' AS section;
SELECT p.product_id, p.product_name, i.warehouse_id, i.quantity, i.reorder_level
FROM Products p INNER JOIN Inventory i ON i.product_id = p.product_id
WHERE p.product_name = 'Wall Clock (Round)';

-- 9.2 UPDATE : raise paper prices by 5 %
UPDATE Products
SET price = ROUND(price * 1.05, 2)
WHERE category = 'Paper';

-- 9.3 UPDATE with JOIN : make Kanpur's reorder levels dynamic = 14 days of average sales
UPDATE Inventory i
INNER JOIN (
    SELECT warehouse_id, product_id, SUM(quantity) / 30 AS avg_daily
    FROM Stock_Movements
    WHERE movement_type = 'OUT'
      AND movement_date BETWEEN DATE_SUB(fn_today(), INTERVAL 30 DAY)
                            AND DATE_SUB(fn_today(), INTERVAL 1 DAY)
    GROUP BY warehouse_id, product_id
) s ON s.warehouse_id = i.warehouse_id AND s.product_id = i.product_id
SET i.reorder_level = CEIL(s.avg_daily * 14)
WHERE i.warehouse_id = 1;

SELECT '### D2: Kanpur reorder levels after the dynamic UPDATE' AS section;
SELECT p.product_name, i.quantity, i.reorder_level
FROM Inventory i
INNER JOIN Products p ON p.product_id = i.product_id
WHERE i.warehouse_id = 1
ORDER BY p.product_id;

-- 9.4 UPDATE : deactivate a supplier
UPDATE Suppliers SET is_active = 0 WHERE name = 'Lucknow Supply House';
UPDATE Suppliers SET is_active = 1 WHERE name = 'Lucknow Supply House';   -- put it back

-- 9.5 DELETE : remove the cancelled order (its order lines vanish via ON DELETE CASCADE)
DELETE FROM Purchase_Orders WHERE status = 'Cancelled';

-- 9.6 DELETE : remove the test product (its inventory line must go first)
DELETE FROM Inventory WHERE product_id = (SELECT product_id FROM (SELECT product_id FROM Products WHERE product_name = 'Wall Clock (Round)') x);
DELETE FROM Products  WHERE product_name = 'Wall Clock (Round)';

SELECT '### D3: Purchase orders left after DELETE (cancelled order 21 gone)' AS section;
SELECT status, COUNT(*) AS orders FROM Purchase_Orders GROUP BY status ORDER BY status;

/* REFERENTIAL INTEGRITY DEMO (kept as a comment because it must FAIL):
   Try to delete a supplier that still has purchase orders:
       DELETE FROM Suppliers WHERE supplier_id = 1;
   MySQL answers: ERROR 1451 - Cannot delete or update a parent row:
   a foreign key constraint fails.  The database protects your data.

   CHECK CONSTRAINT DEMO (must FAIL):
       UPDATE Inventory SET quantity = -5 WHERE inventory_id = 1;
   MySQL answers: ERROR 3819 - Check constraint 'chk_inventory_qty' is violated. */


/* =====================================================================
   PART 10 : TRANSACTION MANAGEMENT
   A transaction groups statements so they ALL succeed (COMMIT) or ALL
   are undone (ROLLBACK). Required for ACID safety.
   ===================================================================== */

-- 10.1 COMMIT : receive purchase order 16 (Metro Distributors -> Kanpur)
SELECT '### T1: Kanpur stock BEFORE receiving order 16' AS section;
SELECT p.product_name, i.quantity, i.reorder_level
FROM Inventory i INNER JOIN Products p ON p.product_id = i.product_id
WHERE i.warehouse_id = 1 AND i.product_id IN (8, 13, 14, 16)
ORDER BY p.product_id;

START TRANSACTION;

    -- (1) mark every line as fully received
    UPDATE Order_Items SET received_quantity = quantity WHERE order_id = 16;

    -- (2) close the order and the shipment
    UPDATE Purchase_Orders SET status = 'Delivered' WHERE order_id = 16;
    UPDATE Logistics SET status = 'Delivered', delivery_date = fn_today() WHERE order_id = 16;

    -- (3) write the stock ledger (IN movements)
    INSERT INTO Stock_Movements (warehouse_id, product_id, movement_type, quantity, movement_date, order_id, remarks)
    SELECT po.warehouse_id, oi.product_id, 'IN', oi.quantity, fn_today(), po.order_id, 'Received PO #16'
    FROM Purchase_Orders po
    INNER JOIN Order_Items oi ON oi.order_id = po.order_id
    WHERE po.order_id = 16;

    -- (4) increase the inventory balances
    UPDATE Inventory i
    INNER JOIN Purchase_Orders po ON po.warehouse_id = i.warehouse_id
    INNER JOIN Order_Items oi ON oi.order_id = po.order_id AND oi.product_id = i.product_id
    SET i.quantity = i.quantity + oi.quantity
    WHERE po.order_id = 16;

    -- (5) register the new batches of the perishable items (tea and water)
    INSERT INTO Inventory_Batches (warehouse_id, product_id, batch_no, quantity, expiry_date) VALUES
    (1, 13, 'TB-2611-C', 350, '2027-11-30'),
    (1, 14, 'WT-2611-C', 400, '2027-10-31');

COMMIT;     -- all five steps are now permanent

SELECT '### T2: Kanpur stock AFTER the COMMIT (chairs no longer below reorder level)' AS section;
SELECT p.product_name, i.quantity, i.reorder_level
FROM Inventory i INNER JOIN Products p ON p.product_id = i.product_id
WHERE i.warehouse_id = 1 AND i.product_id IN (8, 13, 14, 16)
ORDER BY p.product_id;

-- 10.2 ROLLBACK + SAVEPOINT : undo a mistake
START TRANSACTION;

    UPDATE Inventory SET quantity = quantity - 50 WHERE warehouse_id = 1 AND product_id = 1;  -- valid sale
    SAVEPOINT after_valid_sale;

    UPDATE Inventory SET quantity = 0 WHERE warehouse_id = 1;                                  -- oops! wrong WHERE

    SELECT '### T3: inside the transaction after the mistake' AS section;
    SELECT SUM(quantity) AS kanpur_total_units FROM Inventory WHERE warehouse_id = 1;

    ROLLBACK TO SAVEPOINT after_valid_sale;     -- undo ONLY the mistake

    SELECT '### T4: after ROLLBACK TO SAVEPOINT (valid sale kept, mistake undone)' AS section;
    SELECT SUM(quantity) AS kanpur_total_units FROM Inventory WHERE warehouse_id = 1;

ROLLBACK;                                       -- now undo everything

SELECT '### T5: after the final ROLLBACK (nothing changed)' AS section;
SELECT SUM(quantity) AS kanpur_total_units FROM Inventory WHERE warehouse_id = 1;

-- Final proof that the ledger still reconciles after all changes (expect 0 rows)
SELECT '### FINAL CHECK: ledger vs inventory (expect 0 rows)' AS section;
SELECT i.inventory_id, i.quantity AS inventory_qty, l.ledger_qty
FROM Inventory i
LEFT JOIN (
    SELECT warehouse_id, product_id,
           SUM(CASE WHEN movement_type = 'IN' THEN quantity ELSE -quantity END) AS ledger_qty
    FROM Stock_Movements GROUP BY warehouse_id, product_id
) l ON l.warehouse_id = i.warehouse_id AND l.product_id = i.product_id
WHERE i.quantity <> COALESCE(l.ledger_qty, 0);

-- ============================== END OF SCRIPT ==============================
