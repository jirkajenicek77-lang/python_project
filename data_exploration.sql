-- OLIST — Data exploration, cleaning and relational database design
-- This script documents the chronological investigation of the source data, from customer identity and
-- transaction structure to a validated relational model.
-- Execute in stages: exploratory queries, data modifications and schema changes are retained in their
-- original order. This is an analysis log, not an idempotent deployment script.
--
-- === 1. Customer identity and record structure ===
-- Establish whether customer_id identifies a single customer record before using it as a relational key.
select count(*) number_of_rows,
       count(distinct customer_id) as unique_customer_ids,
       count(*) - count(customer_id) as number_of_nulls
from olist.customers;

-- Distinguish customer records from customer identities: customer_unique_id represents the same customer
-- across multiple records.
-- The analysis identified 3,345 records beyond the first record per known identity. This measures record
-- multiplicity, not the number of customers with multiple records. The average records per identity
-- provides an initial measure of that multiplicity.
select count(*) as number_of_rows,
       count(distinct customer_unique_id) unique_physical_customers,
       count(*) - count(customer_unique_id) nulls,
       count(customer_unique_id) - count(distinct customer_unique_id) as extra_customer_records,
       count(customer_id)/nullif(count(distinct customer_unique_id),0) as number_of_records_per_real_customer
from olist.customers;

-- Quantify how many identities contribute to the extra records identified above. The original analysis
-- found 2,997 customers with multiple records.
select count(*) customers_with_more_customer_records
from
(select customer_unique_id,
       count(*)
from olist.customers
group by customer_unique_id
having count(*) > 1) as x;
-- Validation note: If missing customer identities are ever present, exclude them from the grouped
-- population before interpreting this as a customer count.

-- Examine the distribution of records per customer identity to distinguish occasional repetition from
-- customers with many records. This establishes the customer-level grain for subsequent order analysis.
select number_of_records,
       count(customer_unique_id) as number_of_customers
from
(select customer_unique_id,
       count(*) as number_of_records
from olist.customers
group by customer_unique_id) as x
group by number_of_records;


-- === 2. Orders and customer relationships ===
-- Validate the order identifier as the transaction-level key before examining its relationship with
-- customer records.
select count(*) as number_of_orders,
       count(distinct order_id) as unique_number_of_orders,
       count(*) - count(order_id) as nulls_in_orders,
       count(order_id) - count(distinct order_id) as duplicite_orders
from olist.orders;



-- Test whether every order references an existing customer record. Unmatched orders would compromise
-- customer-level metrics; invalid non-null references would also prevent enforcement of the proposed
-- foreign key.
select sum(
            case when c.customer_id is null then 1
                 else 0 end
       ) as number_of_nulls
from olist.orders as o
left join olist.customers as c
on o.customer_id = c.customer_id;


-- Assess whether a customer_id is reused across orders. This helps distinguish the
-- order-to-customer-record relationship from the relationship between orders and persistent customer
-- identities.
select count(customer_id)- count(distinct customer_id) as number_of_duplicite_records
from olist.orders;


-- Measure repeat purchasing at the customer-identity level rather than the customer-record level. The
-- distribution shows the share of observed customers associated with each order count; all order
-- statuses are included.
select *,
       (number_of_customers *100)/nullif(sum(number_of_customers) over(),0) as customers_share_ptc
from
(select number_of_orders,
       count(customer_unique_id) as number_of_customers
from
(select c.customer_unique_id,
       count(*) as number_of_orders
from olist.orders as o
left join olist.customers as c
on o.customer_id = c.customer_id
group by c.customer_unique_id) as x
group by number_of_orders) as x2;


-- Establish the monthly order-volume profile as a baseline for later temporal analysis and assessment of
-- the dataset's coverage.
select cast(date_format(order_purchase_timestamp,'%Y-%m-01') as date) as month,
       count(order_id) as number_of_orders
from olist.orders
group by cast(date_format(order_purchase_timestamp,'%Y-%m-01') as date)
order by month;



-- === 3. Order items: structure, pricing and fulfilment ===
-- Assess the completeness of item identifiers, product and seller references, and monetary fields before
-- using order items for commercial and fulfilment metrics.
select count(*) as number_of_rows,
       sum(
            case when order_id is null then 1 else 0 end
       ) as null_order_id,
           sum(
            case when order_item_id is null then 1 else 0 end
       ) as null_order_item_id,
           sum(
            case when product_id is null then 1 else 0 end
       ) as null_product_id,
           sum(
            case when seller_id is null then 1 else 0 end
       ) as null_seller_id,
           sum(
            case when price is null then 1 else 0 end
       ) as null_price,
           sum(
            case when freight_value is null then 1 else 0 end
       ) as null_freight_value
from olist.order_items;


-- Test whether the combination of order ID and item sequence uniquely identifies an item record, since
-- item sequence numbers are local to an order.
select order_id,
       order_item_id,
       count(*)
from olist.order_items
group by order_id, order_item_id
having count(*) > 1;



-- Identify item records that cannot be linked to an order or lack an item sequence. These are potential
-- integrity issues in the proposed order-item model.
select o.order_id,
       oi.order_item_id
from olist.order_items as oi
left join olist.orders as o
on oi.order_id = o.order_id
where o.order_id is null or oi.order_item_id is null;
-- Suggested revision (not applied):
-- Replace: select o.order_id,
-- With:    select oi.order_id,
-- Reason: The parent order ID is NULL for unmatched records; the source item reference is needed to
-- identify them.



-- Investigate the reverse relationship: orders without items in invoiced, created or shipped status.
-- These cases may reflect incomplete transaction data rather than a foreign-key violation.
select o.order_id,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date
from olist.orders as o
left join olist.order_items as oi
on o.order_id = oi.order_id
where oi.order_id is null and order_status in ('invoiced', 'created', 'shipped');


-- Establish the observed price and freight ranges, check monetary-field completeness and quantify
-- zero-freight items before examining shipping costs relative to product prices.
select max(price) as max_price,
       min(price) as min_price,
       max(freight_value) as max_f_value,
       min(freight_value) as min_f_value,
       sum(
            case when price is null then 1 else 0 end
       ) as null_price,
       sum(
            case when freight_value is null then 1 else 0 end
       ) as null_freight_value,
        sum(
            case when freight_value = 0 then 1 else 0 end
        ) free_shipping
from olist.order_items;
-- Inspect the ten highest freight-to-price ratios to identify extreme shipping costs relative to the
-- value of the item purchased.
select order_id,
       order_item_id,
       product_id,
       seller_id,
       price,
       freight_value,
       (freight_value*100)/nullif(price,0) as freight_share_pct
from olist.order_items
order by freight_share_pct desc
limit 10;

-- Assess how widespread high relative freight costs are by counting items whose freight is at least 30%
-- of their price. Items with an undefined ratio are not included in the threshold count.
select count(*),
       sum(case
                when freight_share_pct >= 30 then 1
                else 0 end ) as over_30_ptc_freight_value
from
(select
       (freight_value*100)/nullif(price,0) as freight_share_pct
from olist.order_items) as x;

-- Establish order-level product value and item count from the item table. Freight is excluded from this
-- definition of order value.
select *
from
(select order_id,
       sum(price) order_price,
       count(*) as number_of_items
from olist.order_items
group by order_id ) as x2;

-- Investigate unusually long shipping allowances by counting items with a shipping deadline more than 30
-- whole days after purchase, segmented by order status. This measures the scheduled allowance, not
-- actual delay.
select order_status,
       sum(over_30_days) as number_of_items
from
(select order_status,
           case when timestampdiff(
               day,
               o.order_purchase_timestamp,
               oi.shipping_limit_date
           ) > 30 then 1 else 0 end
     as over_30_days

from olist.order_items as oi
join olist.orders as o
on oi.order_id = o.order_id) as x
where over_30_days = 1
group by order_status;

-- Assess fulfilment performance by order status, using each item's shipping deadline and the order-level
-- carrier handover timestamp.
-- The resulting late-shipment rate is item-weighted, not order-weighted. Its denominator includes items
-- with a known handover timestamp, even if the deadline is missing. Seller-specific handover times are
-- not available. The maximum delay is a signed difference in whole days.
select *,
       (late_shippments*100)/nullif(number_of_items,0) as late_shippment_rate

from
(select order_status,
       sum(case
                when o.order_delivered_carrier_date > oi.shipping_limit_date then 1
           else 0 end
       ) as late_shippments,
      count(order_delivered_carrier_date) as number_of_items,
      max(timestampdiff(day,oi.shipping_limit_date, o.order_delivered_carrier_date )) as maximum_delay
from olist.order_items as oi
join olist.orders as o
on oi.order_id = o.order_id
group by order_status
) as x;
-- Validation note: Before using this rate as a KPI, verify that shipping deadlines are complete among
-- items with known handover timestamps.


-- === 4. Payments: coverage, structure and anomalies ===
-- Profile payment records and the orders they cover. Check completeness and value ranges before defining
-- payment keys or interpreting payment behaviour.
select count(*) as all_rows,
       count(distinct order_id) as number_of_orders,
       sum(
            case
                when order_id is null then 1 else 0 end
       ) as nulls_order_id,
       sum(
            case
                when payment_sequential is null then 1 else 0 end
       ) as nulls_payment_sequential,
       sum(
            case
                when payment_type is null then 1 else 0 end
       ) as nulls_payment_type,
       sum(
            case
                when payment_installments is null then 1 else 0 end
       ) as nulls_payment_installments,
       sum(
            case
                when payment_value is null then 1 else 0 end
       ) as nulls_payment_value,
        max(payment_value),
        min(payment_value)
from olist.order_payments;


-- Test whether an order ID and payment sequence together identify a payment record by comparing the
-- number of distinct pairs with the total payment-row count.
select count(*)
from
(select order_id,
       payment_sequential
from olist.order_payments
group by order_id, payment_sequential)
as x;

-- Check whether payment records reference valid orders, a prerequisite for the payment-to-order foreign
-- key.
select o.order_id
from olist.order_payments as op
left join olist.orders as o
on op.order_id = o.order_id
where o.order_id is null;
-- Suggested revision (not applied):
-- Replace: select o.order_id
-- With:    select op.order_id
-- Reason: Report the payment-side order reference rather than the missing parent ID.


-- Investigate orders for which no payment record exists. Order status and lifecycle timestamps provide
-- context for evaluating whether the missing payment is consistent with the transaction's state.
select o.order_id,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date
from olist.orders as o
left join olist.order_payments as op
on o.order_id = op.order_id
where op.order_id is null;

-- Inspect item records for a selected order without payments to determine whether its commercial
-- transaction data is also incomplete.
select o.order_id,
       oi.order_item_id
from olist.orders as o
left join olist.order_items as oi
on o.order_id = oi.order_id
where o.order_id = 'bfbd0f9bdef84302105ad712db648a6c';

-- Establish the distribution of payment methods by frequency of payment records. This is not a
-- distribution of order counts or monetary value, since orders may contain multiple payments.
select *,
       (number_of_payments*100)/nullif(sum(number_of_payments) over (),0) as share_ptc_of_payment_types
from
(select payment_type,
       count(*) as number_of_payments
from olist.order_payments
group by payment_type) as x;


-- Investigate records with an undefined payment method to assess their monetary value and position
-- within the payment sequence.
select order_id,
       payment_sequential,
       payment_installments,
       payment_value
from olist.order_payments
where payment_type = 'not_defined'
;

-- Determine whether zero-value payments represent entirely unpaid orders or form part of orders with
-- other payments.
-- For orders containing at least one zero-value payment, retain the complete payment history and
-- calculate the counts of zero and positive payments alongside the total recorded payment value.
-- Negative or missing values belong to neither count.
with zero_vals as
(select distinct order_id

from olist.order_payments
where payment_value = 0),
payment_list as
(select z.order_id,
       o.payment_sequential,
       o.payment_installments,
       o.payment_value,
       o.payment_type
from zero_vals as z
left join olist.order_payments as o
on z.order_id = o.order_id)
select order_id,
       count(*) as total_payments,
       sum(case
                when payment_value = 0 then 1 else 0 end
       ) as number_of_zero_payments,
       sum(case
                when payment_value > 0 then 1 else 0 end
       ) as number_of_positive_payments,
       sum(payment_value) as total_payment_value
from payment_list
group by order_id;


-- Inspect the lifecycle status of selected orders from the payment investigation to contextualise the
-- anomalies identified above.
select op.order_id,
       o.order_status
from olist.order_payments as op
join olist.orders as o
on op.order_id = o.order_id
where op.order_id in ('4637ca194b6387e2d538dc89b124b0ee',
'00b1cb0320190ca0daa2c88b35206009',
'c8c528189310eaa44a745b8d9d26908b');



-- Profile payment records by installment count to identify common financing patterns and unusual
-- installment arrangements.
select *,
       (number_of_payments *100)/ nullif(sum(number_of_payments) over (),0) as share_ptc_of_payment_installments
from
(select payment_installments,
       count(order_id) number_of_payments
from olist.order_payments
group by payment_installments
order by payment_installments) as x;


-- Inspect both ends of the observed installment distribution, focusing on zero and 24 installments.
-- These values require contextual investigation rather than automatic classification as errors.
select *
from olist.order_payments
where payment_installments = 0 or payment_installments = 24
order by payment_installments;


-- Review the status of selected orders with unusual installment counts to determine their transaction
-- context.
select op.order_id,
       o.order_status
from olist.order_payments as op
join olist.orders as o
on op.order_id = o.order_id
where op.order_id in ('744bade1fcf9ff3f31d860ace076d422', '1a57108394169c0b47d8f876acc9ba2d');

-- Investigate incomplete payment sequences, specifically orders with exactly one sequence-2 payment and
-- no sequence-1 or higher-than-2 payments.
-- Retrieve their full payment histories for inspection. The selection does not exclude sequence zero,
-- negative sequences or missing sequence values.
with test as
(select order_id as o_id,
       sum(case
                when payment_sequential = 2 then 1 else null
        end ) as ps_2,
       sum(case
                when payment_sequential = 1 then 1 else null
        end ) as ps_1,
            sum(case
                when payment_sequential > 2 then 1 else null
        end ) as ps_3
from olist.order_payments
group by order_id
having ps_1 is null and ps_2 = 1 and ps_3 is null)
select *
from test as t
inner join olist.order_payments as op
on t.o_id = op.order_id;


-- === 5. Preliminary customer satisfaction analysis ===
-- Explore the relationship between delivery punctuality and customer ratings for delivered orders.
-- Delivery is assessed by calendar date against the estimated delivery date.
-- Compare mean scores and the frequency of negative (below 3), neutral (3) and positive (above 3)
-- reviews across delivery groups, expressing the frequencies as one review in N.
-- This exploratory analysis uses review-level observations; orders with multiple reviews receive greater
-- weight. The final order-level analysis should aggregate reviews per order before comparing delivery
-- groups.
with delivery_table as
(select or2.order_id,
       review_score,
       o.order_status,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,
       case
           when datediff(order_estimated_delivery_date, order_delivered_customer_date) >= 0 then 'In time'
           when datediff(order_estimated_delivery_date, order_delivered_customer_date) < 0 then 'Late'
           else 'Not complete data' end as delivery_status
from olist.order_reviews as or2
left join olist.orders as o
on or2.order_id = o.order_id
where review_score is not null and o.order_status = 'delivered')

select delivery_status,
       number_of_reviews,
       avg_review_score,
       concat('1 in ', round(number_of_reviews/nullif(negative_r,0),1)) as negative_reviews,
       concat('1 in ', round(number_of_reviews/nullif(positive_r,0),1)) as positive_reviews,
       concat('1 in ', round(number_of_reviews/nullif(neutral_r,0),1)) as neutral_reviews
from
(select delivery_status,
       count(*) as number_of_reviews,
       avg(review_score) as avg_review_score,
       sum(case
                when review_score < 3  then 1
                else 0 end
       ) as negative_r,
       sum(case
                when review_score > 3  then 1
                else 0 end
       ) as positive_r,
       sum(case
                when review_score = 3  then 1
                else 0 end
       ) as neutral_r
from delivery_table
group by delivery_status) as x;






-- === 6. Relational integrity validation ===
-- Revisit the candidate keys and relationships before applying database constraints. The customer record
-- identifier is supported by 99,441 distinct IDs across 99,441 rows, with no missing IDs.
select count(distinct customer_id) ,
       count(*),
       count(*) - count(distinct customer_id),
       sum(
            case
                when customer_id is null then 1 else 0 end
       ) as customer_id_nulls
from olist.customers;


-- Confirm that order_id satisfies the completeness and uniqueness requirements of the proposed orders
-- primary key.
select count(distinct order_id) as a,
       count(*) as b,
       count(*) - count(distinct order_id) as c,
              sum(
            case
                when order_id is null then 1 else 0 end
       ) as d
from olist.orders;

-- Validate the proposed composite order-item key against the full item population, including
-- completeness of both components.
select
(select count(*)
from
(select order_id,
       order_item_id
from olist.order_items
group by order_id, order_item_id) as x) - count(*) as a,
           sum(
            case
                when order_id is null then 1 else 0 end
       ) as b,
       sum(
            case
                when order_item_id  is null then 1 else 0 end
       ) as c
from olist.order_items;

-- Check completeness of the two components of the proposed payment primary key.
select
    sum(case
            when order_id is null then 1 else 0  end
    ) as a,
    sum(case
            when payment_sequential is null then 1 else 0  end
    ) as b
from olist.order_payments;

-- Test the payment key for repeated order-and-sequence combinations before enforcing uniqueness.
select order_id,
       payment_sequential,
       count(*) as duplicates
from olist.order_payments
group by order_id, payment_sequential
having count(*) > 1;


-- Verify payment-to-order referential integrity before adding the foreign key.
select *
from olist.order_payments as p
left join olist.orders as o
on p.order_id = o.order_id
where o.order_id is null;


-- Evaluate the composite review key (order_id, review_id), as review_id alone does not uniquely identify
-- a review record. This query isolates repeated key combinations; completeness is assessed separately
-- below.
select order_id,
       review_id,
    sum(case
            when order_id is null then 1 else 0  end
    ) as a,
    sum(case
            when review_id is null then 1 else 0  end
    ) as b,
    count(*) as duplicates
from olist.order_reviews
group by order_id, review_id
having duplicates > 1;

-- Complete the review-key validation by checking both key fields across all review records.
select
    sum(case
            when order_id is null then 1 else 0  end
    ) as a,
    sum(case
            when review_id is null then 1 else 0  end
    ) as b
from olist.order_reviews;


-- Validate the relationship between reviews and their parent orders.
select *
from olist.order_reviews as r
left join olist.orders as o
on r.order_id = o.order_id
where o.order_id is null;


-- Repeat the duplicate-key check for order items as part of the final pre-constraint validation.
select order_id,
       order_item_id,
       count(*) as d
from olist.order_items
group by order_id, order_item_id
having d > 1;

-- Confirm that both components of the order-item key are populated.
select
        sum(case
            when order_id is null then 1 else 0  end
    ) as a,
    sum(case
            when order_item_id is null then 1 else 0  end
    ) as b
from olist.order_items;

-- Validate order references in order_items before enforcing the corresponding foreign key.
select count(*)
from olist.order_items as i
left join olist.orders as o
on i.order_id = o.order_id
where o.order_id is null;


-- Validate product references in order_items so item-level sales can be attributed to the product
-- dimension.
select count(*)
from olist.order_items as i
left join olist.products as p
on i.product_id = p.product_id
where p.product_id is null;

-- Validate seller references in order_items so item-level sales can be attributed to the seller dimension.
select count(*)
from olist.order_items as i
left join olist.sellers as s
on i.seller_id = s.seller_id
where s.seller_id is null;


-- Assess whether seller_id and product_id can serve as the primary keys of their respective entities.
select count(distinct seller_id) as a,
       count(*) as b,
       count(*) - count(distinct seller_id) as c,
       sum(
            case when seller_id is null then 1 else 0 end
       ) as d
from olist.sellers
union
select count(distinct product_id) as a,
       count(*) as b,
       count(*) - count(distinct product_id) as c,
       sum(
            case when product_id is null then 1 else 0 end
       ) as d
from olist.products;
-- Suggested revision (not applied):
-- Replace: union
-- With:    union all
-- Reason: Keep the seller and product validation results separate even if their summary values coincide.



-- Measure product catalogue coverage in the transaction data. Products without item records do not
-- violate referential integrity but may affect catalogue-level analysis.
select count(*)
from olist.products as p
left join olist.order_items as i
on p.product_id = i.product_id
where i.product_id is null;

-- Measure seller coverage in the transaction data and identify sellers without recorded order items.
select count(*)
from olist.sellers as p
left join olist.order_items as i
on p.seller_id = i.seller_id
where i.seller_id is null;

-- Consolidate the final uniqueness and completeness checks for the customer and order identifiers.
select count(distinct customer_id) as a,
       count(*) as b,
       count(*) - count(distinct customer_id) as c,
       sum(
            case when customer_id is null then 1 else 0 end
       ) as d
from olist.customers
union all
select count(distinct order_id) as a,
       count(*) as b,
       count(*) - count(distinct order_id) as c,
       sum(
            case when order_id is null then 1 else 0 end
       ) as d
from olist.orders;


-- Confirm that customer_unique_id describes a persistent customer identity rather than a unique
-- customer-table record, making it unsuitable as the primary key of this table.
select count(distinct customer_unique_id) as a,
       count(*) as b,
       count(*) - count(distinct customer_unique_id) as c,
       sum(
            case when customer_unique_id is null then 1 else 0 end
       ) as d
from olist.customers;


-- Quantify repeated customer identities again to support the decision to retain customer_id as the
-- record-level key.
select count(*)
from
(select customer_unique_id,
       count(*) as number_of_records
from olist.customers
group by customer_unique_id
having number_of_records > 1) as x;


-- Confirm that item sequence numbers are reused across orders, supporting the composite rather than
-- single-column order-item key.
select order_item_id,
       count(*) as d
from olist.order_items
group by order_item_id
having d > 1;

-- Assess the completeness and uniqueness of the category translation mapping. The original table
-- contained 71 rows; the Portuguese category name is the proposed relationship key.
select count(distinct product_category_name) as a,
       count(*) as b,
       count(*) - count(distinct product_category_name) as c,
       count(*) - count(distinct product_category_name_english) as t,
       sum(
        case when product_category_name is null then 1 else 0 end
       ) as d,
       sum(
        case when product_category_name_english is null then 1 else 0 end
       ) as e
from olist.product_category_name_translation;


-- === 7. Geolocation structure and remaining reference checks ===
-- Assess whether the raw geographic data can support a ZIP-prefix lookup. The source contains 1,000,163
-- records covering 19,015 distinct prefixes, with no missing prefixes. The repeated prefixes rule out a
-- direct primary key on the raw table.
select count(distinct geolocation_zip_code_prefix) as a,
       count(*) as b,
       count(*) - count(distinct geolocation_zip_code_prefix) as c,
       sum(
            case
                when geolocation_zip_code_prefix is null then 1 else 0 end
       ) as d
from olist.geolocation;


-- Test whether combining ZIP prefix and city resolves the repeated-record problem. The original analysis
-- found 18,221 repeated prefix-city groups.
select geolocation_zip_code_prefix,
       geolocation_city,
       count(*) as x
from olist.geolocation
group by geolocation_zip_code_prefix, geolocation_city
having x > 1;


-- Investigate the consistency of city labels within ZIP prefixes. Multiple observed labels may represent
-- spelling variants or genuinely different localities; the distinction is important for the geographic
-- lookup design.
select geolocation_zip_code_prefix,
       count(distinct geolocation_city) as x
from olist.geolocation
group by geolocation_zip_code_prefix
having x > 1
order by x desc ;


-- Inspect a representative ambiguous prefix (13454) to examine the spelling and punctuation variations
-- behind the conflicting city labels.
select *
from olist.geolocation
where geolocation_zip_code_prefix = '13454';



-- Complete the order-to-customer integrity check before applying the main relational constraints.
select count(*)
from olist.orders as c
left join olist.customers as o
on c.customer_id= o.customer_id
where o.customer_id is null;




-- Identify non-null product categories that cannot be linked to the translation table. The original
-- analysis found 13 products across two missing categories.
select *
from olist.products as p
left join olist.product_category_name_translation as pt
on p.product_category_name = pt.product_category_name
where pt.product_category_name is null and p.product_category_name is not null;


-- Compare the number of observed product categories with translation-table coverage before extending the
-- mapping.
select count(distinct product_category_name)
from olist.products;

-- Extend the category mapping with the two missing Portuguese labels and manually selected English
-- translations. This resolves the known non-null category references before enforcing the relationship.
insert into olist.product_category_name_translation
values ('portateis_cozinha_e_preparadores_de_alimentos','kitchen_appliances_and_food_preparation_tools'),
       ('pc_gamer', 'pc_gamer');


-- === 8. Implement the validated relational model ===
-- Apply the previously validated primary keys. Customers, orders, products and sellers use entity
-- identifiers; items, payments and reviews require composite keys. The category mapping uses its
-- source-language label.
alter table olist.customers
add primary key (customer_id);


alter table olist.orders
add primary key (order_id);


alter table olist.order_items
add primary key (order_id,order_item_id);

alter table olist.order_payments
add primary key (order_id,payment_sequential);

alter table olist.order_reviews
add primary key (order_id, review_id);

alter table olist.products
add primary key (product_id);

alter table olist.sellers
add primary key (seller_id);

alter table olist.product_category_name_translation
add primary key (product_category_name);


-- Enforce the validated relationships between orders and customer records, and between orders, items,
-- products, sellers, payments and reviews. These constraints preserve the source transaction grain while
-- preventing orphan references.
alter table olist.orders
add constraint fk_orders_customer
foreign key (customer_id)
references olist.customers(customer_id);



alter table olist.order_items
add constraint fk_item_orders
foreign key (order_id)
references olist.orders(order_id);

alter table olist.order_items
add constraint fk_items_products
foreign key (product_id)
references olist.products(product_id);

alter table olist.order_items
add constraint fk_items_sellers
foreign key (seller_id)
references olist.sellers(seller_id);

alter table olist.order_payments
add constraint  fk_payments_orders
foreign key (order_id)
references olist.orders(order_id);

alter table olist.order_reviews
add constraint fk_reviews_orders
foreign key (order_id)
references olist.orders(order_id);

-- Complete the product-category relationship using the expanded translation mapping. Missing category
-- values remain permissible rather than being assigned an unsupported category.
alter table olist.products
add constraint fk_products_category_name
foreign key (product_category_name)
references olist.product_category_name_translation(product_category_name)
;

-- Inspect the implemented review table definition to verify that its composite key and order
-- relationship were created as intended.
SHOW CREATE TABLE olist.order_reviews;


-- === 9. Geolocation cleaning and resolution of conflicting labels ===
-- Identify ZIP prefixes assigned to multiple states and quantify the evidence for each state assignment.
-- Eight prefixes exhibited conflicts in the source data.
select x.geolocation_zip_code_prefix,
       g.geolocation_state,
       count(*) as number_of_records
from
(select geolocation_zip_code_prefix,
       count(distinct geolocation_state) as number_of_states
from olist.geolocation
group by geolocation_zip_code_prefix
having number_of_states > 1) as x
inner join olist.geolocation as g
on x.geolocation_zip_code_prefix = g.geolocation_zip_code_prefix
group by x.geolocation_zip_code_prefix, geolocation_state
order by geolocation_zip_code_prefix



;
-- Preserve the raw geographic observations and perform corrections on a separate working table so that
-- the original data remains available for comparison and audit.
create table olist.geolocation_fix as
select *
from olist.geolocation;


-- Establish the state-conflict baseline in the working table. Repeat this check after the corrections to
-- confirm that the one-state-per-prefix rule holds.
select x.geolocation_zip_code_prefix,
       g.geolocation_state,
       count(*) as number_of_records
from
(select geolocation_zip_code_prefix,
       count(distinct geolocation_state) as number_of_states
from olist.geolocation_fix
group by geolocation_zip_code_prefix
having number_of_states > 1) as x
inner join olist.geolocation_fix as g
on x.geolocation_zip_code_prefix = g.geolocation_zip_code_prefix
group by x.geolocation_zip_code_prefix, geolocation_state
order by geolocation_zip_code_prefix;

-- Resolve the first seven state conflicts using the most frequently observed state for each prefix,
-- modifying only minority-state records. This is a data-driven consistency rule, not an independently
-- verified geographic correction.
update olist.geolocation_fix
set geolocation_state = 'SP'
where geolocation_zip_code_prefix = '02116' and geolocation_state = 'RN';

update olist.geolocation_fix
set geolocation_state = 'SP'
where geolocation_zip_code_prefix = '04011' and geolocation_state = 'AC';

update olist.geolocation_fix
set geolocation_state = 'RJ'
where geolocation_zip_code_prefix = '21550' and geolocation_state = 'AC';

update olist.geolocation_fix
set geolocation_state = 'RJ'
where geolocation_zip_code_prefix = '23056' and geolocation_state = 'AC';

update olist.geolocation_fix
set geolocation_state = 'GO'
where geolocation_zip_code_prefix = '72915' and geolocation_state = 'DF';

update olist.geolocation_fix
set geolocation_state = 'MT'
where geolocation_zip_code_prefix = '78557' and geolocation_state = 'RO';

update olist.geolocation_fix
set geolocation_state = 'MS'
where geolocation_zip_code_prefix = '79750' and geolocation_state = 'RS';

-- Resolve the remaining state conflict for prefix 80630 using PR, its most frequent source state.
update olist.geolocation_fix
set geolocation_state = 'PR'
where geolocation_zip_code_prefix = '80630';
-- Validation checkpoint: Repeat the state-conflict query above after all eight updates. The expected
-- result is zero conflicting prefixes.

-- With state conflicts addressed, investigate city-label ambiguity. The original analysis identified 551
-- prefixes with multiple observed city labels. Differences may reflect either naming variations or
-- different localities.
select x.geolocation_zip_code_prefix,
       g.geolocation_city,
       count(*) as number_of_cities_
from
(select geolocation_zip_code_prefix,
       count(distinct geolocation_city) as number_of_cities
from olist.geolocation_fix
group by geolocation_zip_code_prefix
having number_of_cities > 1
order by number_of_cities desc
) as x
inner join olist.geolocation_fix as g
on x.geolocation_zip_code_prefix = g.geolocation_zip_code_prefix
group by x.geolocation_zip_code_prefix, g.geolocation_city;




-- Test whether selecting the most frequent city label would produce an unambiguous result for every
-- prefix. The analysis found 35 prefixes with tied leading labels (70 rows), so frequency alone cannot
-- resolve all cases reliably.
WITH city_counts AS (
    SELECT
        geolocation_zip_code_prefix,
        geolocation_city,
        COUNT(*) AS n
    FROM olist.geolocation_fix
    GROUP BY geolocation_zip_code_prefix, geolocation_city
),
ranked AS (
    SELECT
        *,
        rank() OVER (
            PARTITION BY geolocation_zip_code_prefix
            ORDER BY n DESC
        ) AS rn
    FROM city_counts
)
select *
from
(select geolocation_zip_code_prefix,
       count(*) as c
from
(SELECT *
FROM ranked
WHERE rn = 1) as x
group by geolocation_zip_code_prefix
having c > 1) as x2
inner join ranked as r
on x2.geolocation_zip_code_prefix = r.geolocation_zip_code_prefix
where rn = 1
order by x2.geolocation_zip_code_prefix;


-- Evaluate mean coordinates as a potential representative location for each ZIP prefix. Because the mean
-- is sensitive to anomalous coordinates, the subsequent lookup adopts component-wise medians instead.
select geolocation_zip_code_prefix,
       geolocation_state,
       avg(geolocation_lat),
       avg(geolocation_lng)
from olist.geolocation_fix
group by geolocation_zip_code_prefix,geolocation_state;


-- === 10. Representative coordinates and ZIP lookup construction ===
-- Derive representative latitude and longitude for each ZIP prefix from the median of each coordinate
-- independently. This reduces sensitivity to extreme observations and avoids choosing an arbitrary raw
-- record.
-- Combine the estimates with the cleaned state assignment. The resulting location is an approximation,
-- not necessarily an observed coordinate pair. The median calculation assumes complete coordinate
-- observations; no separate coordinate-outlier filter is applied.
create table olist.geo_fix as
with c_lat as
(select geolocation_zip_code_prefix,
       avg(geolocation_lat) as lat
from
(select *
from
(select geolocation_zip_code_prefix,
       geolocation_lat,
       row_number() over (partition by geolocation_zip_code_prefix order by geolocation_lat asc) as r1,
       count(*) over (partition by geolocation_zip_code_prefix) r2
from olist.geolocation_fix
) as x
where (r2/2) = r1 or (r2/2 +0.5 = r1) or (r2/2) +1 = r1
) as x2
group by geolocation_zip_code_prefix),


c_lng as
(select geolocation_zip_code_prefix,
       avg(geolocation_lng) as lng
from
(select *
from
(select geolocation_zip_code_prefix,
       geolocation_lng,
       row_number() over (partition by geolocation_zip_code_prefix order by geolocation_lng asc) as r1,
       count(*) over (partition by geolocation_zip_code_prefix) r2
from olist.geolocation_fix
) as x
where (r2/2) = r1 or (r2/2 +0.5 = r1) or (r2/2) +1 = r1
) as x2
group by geolocation_zip_code_prefix
)


select x.geolocation_zip_code_prefix,
       x.lat,
       x.lng,
       gf.geolocation_state
from
(select c.geolocation_zip_code_prefix,
       c.lat,
       l.lng
from c_lat as c
join c_lng as l
on c.geolocation_zip_code_prefix = l.geolocation_zip_code_prefix) as x
inner join olist.geolocation_fix as gf
on x.geolocation_zip_code_prefix = gf.geolocation_zip_code_prefix
group by x.geolocation_zip_code_prefix, gf.geolocation_state, x.lat, x.lng;
-- Validation note: Verify coordinate completeness before relying on the median calculation; if missing
-- values exist, filter them separately in the latitude and longitude ranking populations.


-- Create a ZIP-level geographic lookup with representative coordinates and state. Retain distinct
-- observed city labels rather than arbitrarily choosing among ambiguous or tied labels. The original
-- lookup covered 19,015 prefixes.
-- The city field preserves source-label ambiguity and may contain spelling variants; it is not a
-- standardised city dimension.
create table olist.geolocation_
select gf.geolocation_zip_code_prefix,
       gf.lat,
       gf.lng,
       gf.geolocation_state,
       group_concat( distinct gx.geolocation_city) as city
from olist.geo_fix as gf
inner join olist.geolocation_fix as gx
on gf.geolocation_zip_code_prefix = gx.geolocation_zip_code_prefix
group by gf.geolocation_zip_code_prefix, gf.lat, gf.lng, gf.geolocation_state;
-- Validation note: Verify that retained city labels fit the configured GROUP_CONCAT output length and
-- that the lookup has exactly one row per prefix.

-- Inspect the constructed lookup before assessing its coverage of customer and seller locations.
select *
from olist.geolocation_;


-- === 11. Geographic coverage and missing ZIP prefixes ===
-- Measure customer coverage in the new lookup. The original investigation identified 278 customer
-- records across 157 prefixes absent from the geolocation source.
select c.customer_zip_code_prefix,
       count(*) as number_of_records
from olist.customers as c
left join olist.geolocation_ as g
on c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
where g.geolocation_zip_code_prefix is null
group by c.customer_zip_code_prefix
order by number_of_records desc ;




-- Distinguish absent lookup entries from missing customer ZIP identifiers. The original check found no
-- missing customer prefixes.
select
       count(*) as number_of_records
from olist.customers as c
left join olist.geolocation_ as g
on c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
where c.customer_zip_code_prefix is null;

-- Remove the previous staging table before rebuilding the list of uncovered ZIP prefixes.
drop table olist.zip_;
-- Suggested revision (not applied):
-- Replace: drop table olist.zip_;
-- With:    drop table if exists olist.zip_;
-- Reason: Allow this staging step to run when the previous table does not exist.
-- Consolidate all customer and seller prefixes absent from the geographic lookup. Seven sellers
-- contributed seven prefixes; two overlapped the customer list, leaving 162 distinct prefixes to add.
create table olist.zip_ as
(with cte1 as (
select  seller_zip_code_prefix,
        count(*) as number_of_sellers,
        sum(case
                when seller_zip_code_prefix is null then 1
                else 0 end
        ) as nulls_sellers_prefix
from olist.sellers as s
left join olist.geolocation_ as g
on s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
where g.geolocation_zip_code_prefix is null
group by s.seller_zip_code_prefix),

    cte2 as (
select c.customer_zip_code_prefix,
       count(*) as number_of_records
from olist.customers as c
left join olist.geolocation_ as g
on c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
where g.geolocation_zip_code_prefix is null
group by c.customer_zip_code_prefix
order by number_of_records desc
)
select x.seller_zip_code_prefix as unique_zip_codes
from
(select c1.seller_zip_code_prefix
from cte1 as c1
union
select c2.customer_zip_code_prefix
from cte2 as c2) as x
group by unique_zip_codes)
;

-- Remove the previous geographic staging table before rebuilding the supplemental location data.
drop table olist.zipp;
-- Suggested revision (not applied):
-- Replace: drop table olist.zipp;
-- With:    drop temporary table if exists olist.zipp;
-- Reason: The following statement creates a temporary table; restrict the drop to that object type.
-- Recover available state and city labels for the uncovered prefixes directly from customer and seller
-- records. The original analysis reported no conflicts among these known labels, although the conflict
-- check is not retained in this script. The temporary staging table is session-specific.
create temporary table olist.zipp as
(select unique_zip_codes as zip_code,
       s.seller_state as state,
       s.seller_city as city
from olist.zip_ as z
join olist.sellers as s
on z.unique_zip_codes = s.seller_zip_code_prefix
UNION
select unique_zip_codes,
       c.customer_state,
       c.customer_city
from olist.zip_ as za
join olist.customers as c
on za.unique_zip_codes = c.customer_zip_code_prefix);


-- Extend the geographic lookup with the recovered prefixes and their available location labels. Retain
-- missing coordinates as NULL rather than inventing representative locations without source
-- observations.
insert into olist.geolocation_ (geolocation_zip_code_prefix, geolocation_state, city)
select *
from olist.zipp;

-- Reconcile the lookup population after supplementation: 19,015 original prefixes plus 162 additional
-- prefixes gives 19,177 expected records.
select count(*)
from olist.geolocation_;



-- === 12. Final geographic validation and model completion ===
-- Validate that the completed lookup contains one record per ZIP prefix and assess field completeness.
-- The original analysis recorded 162 missing latitudes and 162 missing longitudes, with no missing city
-- or state labels.
select count(*) as all_records,
       count(distinct geolocation_zip_code_prefix) as unique_zip_codes,
       sum(
            case
                when geolocation_zip_code_prefix is null then 1
                else 0 end
       ) as nulls_zip_code,
       sum(
            case
                when lat is null then 1
                else 0 end
       ) as nulls_lat,
       sum(
            case
                when lng is null then 1
                else 0 end
       ) as nulls_lng,
       sum(
            case
                when city is null then 1
                else 0 end
       ) as nulls_city,
       sum(
            case
                when geolocation_state is null then 1
                else 0 end
       ) as nulls_state
from olist.geolocation_;


-- Confirm that every seller prefix is now represented in the lookup. The original validation returned
-- zero unmatched records.
select count(*)
from olist.sellers as s
left join olist.geolocation_ as g
on s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
where g.geolocation_zip_code_prefix is null;

-- Confirm that every customer prefix is now represented in the lookup. The original validation returned
-- zero unmatched records.
select count(*)
from olist.customers as c
left join olist.geolocation_ as g
on c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
where g.geolocation_zip_code_prefix is null;




-- Enforce ZIP-prefix uniqueness in the completed geographic lookup, establishing the geographic
-- dimension's grain.
alter table olist.geolocation_
add primary key (geolocation_zip_code_prefix);


-- Link customer records to the geographic dimension without changing their record-level grain.
alter table olist.customers
add constraint fk_customers_geolocation
foreign key (customer_zip_code_prefix)
references olist.geolocation_(geolocation_zip_code_prefix);

-- Link seller records to the same geographic dimension. This completes the nine foreign keys in the main
-- relational model; the raw and staging geographic tables remain separate.
alter table olist.sellers
add constraint fk_sellers_geolocation
foreign key (seller_zip_code_prefix)
references olist.geolocation_(geolocation_zip_code_prefix);


