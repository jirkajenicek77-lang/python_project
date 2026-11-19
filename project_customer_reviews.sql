
-- reviews in relation with latency
-- Findings are that, when is a delivery late its 6,7 times more likely to get negative review than when it's on time.
-- we can see
-- Latency reviews Table
with delivery_table as
(select or2.order_id,
       review_score,
       o.order_status,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,
       case
           when datediff(cast(date_format(order_estimated_delivery_date,'%Y-%m-%d') as date),cast(date_format(order_delivered_customer_date,'%Y-%m-%d') as date)) >= 0 then 'In time'
           else 'Late' end as delivery_status
from olist.orders as o
left join olist.order_reviews as or2
on or2.order_id = o.order_id
where review_score is not null and o.order_status = 'delivered')

select delivery_status,
       number_of_reviews,
       avg_review_score,
       concat('1 in ', round(number_of_reviews/nullif(negative_r,0),1)) as negative_reviews,
       concat('1 in ', round(number_of_reviews/nullif(positive_r,0),1)) as positive_reviews,
       concat('1 in ', round(number_of_reviews/nullif(neutral_r,0),1)) as neutral_reviews,
       positive_r,
       neutral_r,
       negative_r
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



-- findings: group of delivered orders is 97% of all orders, so I will continue explore more of this group
--  reviews drops significantly after 1-2 days its 0,78 point, after 3-5 days its 1,83 points and  6-10 days is 2,52 points after that ist plateau the 10+ days is 2,58 points
-- 6.76% of orders are late and 93,23% orders are on time a few orders have no delivery time, but its so small amount that is not important
-- delivery performance exploration
with o_reviews as (
select order_id,
       avg(review_score) as review_score
from olist.order_reviews
group by order_id
)

select *,
       (number_of_deliveries *100 )/nullif(sum(number_of_deliveries) over(),0) as ptc_share,
       (number_of_deliveries *100 )/nullif(sum(number_of_deliveries) over(partition by order_status),0) as pt_share_o_stat
from
(select x.order_status,
       case
           when delivery_accuracy >= 0 then 'On time'
           when delivery_accuracy < 0 and delivery_accuracy >= -2 then 'Late 1-2 days'
           when delivery_accuracy < -2 and  delivery_accuracy >= -5 then 'Late 3-5 days'
           when delivery_accuracy < -5 and delivery_accuracy >= -10 then 'Late 6-10 days'
           when delivery_accuracy < -10 then  'Late more than 10 days' end as delivery_latency,
       count(distinct order_id) as number_of_deliveries,
       avg(review_score) as average_review_score

from
(select o.order_status,
       datediff(cast(date_format(order_estimated_delivery_date,'%Y-%m-%d') as date),cast(date_format(order_delivered_customer_date,'%Y-%m-%d') as date)) as delivery_accuracy,
       review_score,
       o.order_id
from olist.orders as o
left join o_reviews as or2
on or2.order_id = o.order_id ) as x
group by x.order_status, delivery_latency
order by x.order_status) as x2;




-- 8 customer which has products delivered, but no time of delivery, so I assume they bought it at facility or came took it from carrier
select *
from olist.orders
where order_id in ('0d3268bad9b086af767785e3f0fc0133',
'e69f75a717d64fc5ecdfae42b2e8e086',
'f5dd62b788049ad9fc0526e3ad11a097',
'2d858f451373b04fb5c984a1cc2defaf',
'2ebdfc4f15f23b91474edf87475f108e',
'2d1e2d5bf4dc7227b3bfebb81328c15f',
'20edc82cf5400ce95e1afacc25798b31',
'ab7c89dc1bf4a1ead9d6ec1ec8968a84'
);


-- exploration of sellers
-- after basic sellers exploratory we need to extract the most important sellers by Pareto principle
with sellers as
(select seller_id,
       order_id,
       sum(price) as value,
       avg(delivery_accuracy) as avg_d
from
(select s.seller_id,
        o.order_id,
        ot.price,
       datediff(cast(date_format(order_estimated_delivery_date,'%Y-%m-%d') as date),cast(date_format(order_delivered_customer_date,'%Y-%m-%d') as date)) as delivery_accuracy
from olist.sellers as s
join olist.order_items as ot
on s.seller_id = ot.seller_id
join olist.orders as o
on ot.order_id = o.order_id
) as x
group by seller_id, order_id),

reviews as
(select order_id,
       avg(review_score) as review_score
from olist.order_reviews
group by order_id
),
sellers_exp as
(
select s.seller_id,
       count(s.order_id) as number_of_orders,
       avg(s.avg_d) as avg_delivery_accuracy,
       sum(s.value) as value_of_all_orders,
       avg(r.review_score) as average_review_score
from sellers as s
left join reviews as r
on s.order_id = r.order_id
group by s.seller_id
),
-- sellers given importance factors
importance_factors as
(select *,
       sum(value_of_all_orders) over (order by sellers_rank rows between unbounded preceding and current row ) as cumulative_sum,
       (sum(value_of_all_orders) over (order by sellers_rank rows between unbounded preceding and current row )*100)/
       nullif(sum(value_of_all_orders) over (),0) as cumulative_ptc
from
(select *,
       row_number()  over (order by value_of_all_orders desc, number_of_orders desc) as sellers_rank
from sellers_exp) as x),

-- here we can see that 4,16% of seller brings 50% of revenue and 17,54% of selleres brings 80% of revenue
-- also we can see that avg_review is around 4 +- 0,1 point
-- we will further explore top 17,54% of sellers as we decided, they are the most important group
--  Average review score,looks at orders where seller was a part of sell, if you have more than 1 seller it can case some issues
/*select ptc_grp,
       number_of_sellers,
       (number_of_sellers*100)/nullif(sum(number_of_sellers) over (),0) as share_ptc_of_sellers,
       sum_value,
       number_of_orders_,
       sum_avg_review/number_of_sellers as avg_review_score_
from
(select ptc_grp,
       sum(average_review_score) as sum_avg_review,
       sum(value_of_all_orders) sum_value,
       sum(number_of_orders) number_of_orders_,
       count(*) as number_of_sellers
from
(select *,
       case
           when cumulative_ptc <= 30 then 'top 30%'
           when cumulative_ptc <= 50 then 'top 31-50%'
           when cumulative_ptc <= 80 then 'top 51-80%'
           when cumulative_ptc > 80 then  'more than 81%' end as ptc_grp
from importance_factors) as x
group by ptc_grp) as x2
*/

-- here we can see that 542 seller makes 80% of our revenue, to be clear I will get rid of sellers which has less than 10 orders
-- we are left with 506 sellers now I will separate them to 3 categories by customer review
-- because we put out sellers without 10 or more orders, last 506 sellers makes 77,6% of all revenue
important_seller as
(select seller_id,
       value_of_all_orders,
       average_review_score,
       number_of_orders
from
(
select *,
       case
           when cumulative_ptc <= 30 then 'top 30%'
           when cumulative_ptc <= 50 then 'top 31-50%'
           when cumulative_ptc <= 80 then 'top 51-80%'
           when cumulative_ptc > 80 then  'more than 81%' end as ptc_grp
from importance_factors
) as x
where ptc_grp in ('top 30%','top 31-50%','top 51-80%') and number_of_orders >=10
order by average_review_score),

-- here we can see that 68,5% of the best performing sellers are in good reviews category with 67,3% of orders with 69,9% of revenue
-- 30% of medium with 32% of orders and 28,8% revenue and 1,3% of bad sellers with 0,5% of orders and 1,2% of revenue
-- I will further investigate sellers with bad and medium reviews which makes 30% of revenue

/*
select *,
       (number_of_sellers*100)/nullif(sum(number_of_sellers) over (),0) as share_ptc_selleres,
       (number_of_orders*100)/nullif(sum(number_of_orders) over (),0) as share_ptc_orders,
       (revenue*100)/nullif(sum(revenue) over (),0) as share_ptc_revenue
from
(select review_category,
       count(seller_id) as number_of_sellers,
       sum(number_of_orders) number_of_orders,
       sum(value_of_all_orders) as revenue
from
(select *,
        case
            when average_review_score < 3 then 'bad reviews'
            when average_review_score >=3 and average_review_score < 4 then 'medium reviews'
            when average_review_score >= 4 then 'good reviews'
        end  as review_category
from important_seller) as x
group by review_category) as x2;
*/



bad_sellers as
(select *
from
(select *,
        case
            when average_review_score < 3 then 'bad reviews'
            when average_review_score >=3 and average_review_score < 4 then 'medium reviews'
            when average_review_score >= 4 then 'good reviews'
        end  as review_category
from important_seller) as x
where review_category in ('bad reviews','medium reviews') and number_of_orders >= 10),
sell_rewies as
(select s2.seller_id,
        s2.value,
        s2.order_id,
        r2.review_score,
        s2.avg_d as aveage_delivery
from sellers as s2
left join reviews as r2
on s2.order_id = r2.order_id
),
good_sellers as
(select *
from
(select *,
        case
            when average_review_score < 3 then 'bad reviews'
            when average_review_score >=3 and average_review_score < 4 then 'medium reviews'
            when average_review_score >= 4 then 'good reviews'
        end  as review_category
from important_seller) as x
where review_category = 'good reviews' and number_of_orders >= 10)
-- here we can see all bad sellers different orders and their latency
-- here we can see same fall of reviews even when its just the bad sellers
-- I can see strong coleration between review and delivery latency
-- also did the same test with good sellers and here we can see same fall of the rating the longer it takes to deliver
-- only difference is that good sellers has higher avg_reviews by 0.2% than bad
-- bad sellers has 1 in 8,3 orders late and good sellers has 1 in 12,7 orders late
select delivery_latency,
       avg(review_score) agv_review,
       count(*) number_of_orders
from
(
select *,
       case
           when delivery_accuracy >= 0 then 'On time'
           when delivery_accuracy < 0 and delivery_accuracy >= -2 then 'Late 1-2 days'
           when delivery_accuracy < -2 and  delivery_accuracy >= -5 then 'Late 3-5 days'
           when delivery_accuracy < -5 and delivery_accuracy >= -10 then 'Late 6-10 days'
           when delivery_accuracy < -10 then  'Late more than 10 days' end as delivery_latency
from
(select bs.seller_id,
       sr.order_id,
       sr.review_score,
       sr.value,
       sr.aveage_delivery as delivery_accuracy
/*from bad_sellers as bs
inner join sell_rewies as sr
on bs.seller_id= sr.seller_id*/
from good_sellers as bs
inner join sell_rewies as sr
on bs.seller_id = sr.seller_id
) as x) as x2
group by delivery_latency
order by agv_review desc
;

