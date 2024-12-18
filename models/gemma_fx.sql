{{ config(enabled=var("gemma:fx:enabled")) }}

/*
 At each dbt invocation, dbt reads all projce-related files and constructs a "manifest", 
 used to build the DAG later on. During parsing, Jinja statements like config(), ref() 
 or source() are evaluated. Thus, during parsing, dbt will evaluate the if-else
 statements in this model, irrespective of whether the model is enabled or not and 
 whether it is actually called or not. 
 
 We explicitly check for whether the model is enabled, so that we can trigger an 
 exception if the model is enabled, but an unsupported adapter is used. 
*/
{% if var("gemma:fx:enabled") and (target.type == 'postgres' or target.type == 'redshift') | as_bool() %}

WITH rates AS (

  {% for currency, source_table in var('gemma:fx:currencies').items() %}

    SELECT
        formatted_date
      , '{{ currency|upper() }}' AS currency
      , adjclose
    FROM {{ var(source_table, source_table) }}
    {# Checks if there is a variable called source_table. If there is not, source_table
    may already be the name of the table. #}

    {% if not loop.last %}

      UNION ALL

    {% endif %}

  {% endfor %}

), remove_nulls AS (

  SELECT
      formatted_date::DATE AS date
    , currency
    , adjclose AS fx_rate_usd
    , COALESCE( -- the GENERATE_SERIES below throws out the very last day otherwise!
          LEAD(formatted_date::DATE) OVER w
        , (NOW()::DATE + INTERVAL '1 day')::DATE
        -- use NOW() to ensure that date series runs to current date even on holidays!
      ) AS next_date
    , ROW_NUMBER() OVER w AS temp_partition
  FROM rates
  WHERE NOT NULLIF(adjclose, 0) IS NULL -- throw out rows without proper fx rate
  WINDOW w AS (PARTITION BY currency ORDER BY formatted_date::DATE ASC)

), add_missing_dates AS (

  SELECT
      gs.gs::DATE AS date
    , rn.currency
    , FIRST_VALUE(rn.fx_rate_usd) OVER w AS fx_rate_usd
  FROM remove_nulls AS rn
    , GENERATE_SERIES(rn.date, rn.next_date - INTERVAL '1 day', INTERVAL '1 day') AS gs
  WINDOW w AS (PARTITION BY rn.currency, rn.temp_partition ORDER BY rn.date ASC)

), add_usd AS (

  WITH minmax AS (SELECT MIN(date) AS min, MAX(date) AS max FROM add_missing_dates)

  SELECT * FROM add_missing_dates
  UNION ALL
  SELECT
      GENERATE_SERIES(mm.min, mm.max, INTERVAL '1 day')::DATE AS date
    , 'USD'
    , 1
  FROM minmax AS mm

), base_currency AS (

  SELECT * FROM add_usd
  WHERE currency = '{{ var("gemma:fx:base_currency")|upper() }}'

), final AS (

  SELECT
      au.date
    , au.currency AS fx_currency
    , bc.currency AS base_currency
    , bc.fx_rate_usd / au.fx_rate_usd AS fx_rate
  FROM add_usd AS au
    LEFT JOIN base_currency AS bc
      ON bc.date = au.date

)

SELECT * FROM final
ORDER BY date DESC, fx_currency ASC

{% elif var("gemma:fx:enabled") and target.type == 'snowflake' | as_bool() %}

  WITH rates AS (

    {% for currency, source_table in var('gemma:fx:currencies').items() %}

      SELECT
          "formatted_date" AS formatted_date
        , '{{ currency|upper() }}' AS currency
        , "adjclose" AS adjclose
      FROM {{ var(source_table, source_table) }}
      {# Checks if there is a variable called source_table. If there is not, source_table
      may already be the name of the table. #}

      {% if not loop.last %}

        UNION ALL

      {% endif %}

    {% endfor %}

  ), remove_nulls AS (

    SELECT
        TO_DATE (formatted_date) AS date
      , currency
      , adjclose AS fx_rate_usd
      , COALESCE(
            LEAD(formatted_date::DATE) OVER (PARTITION BY currency ORDER BY date ASC)
            , DATEADD(day, 1, CURRENT_DATE())) AS next_date
      , ROW_NUMBER() OVER (PARTITION BY currency ORDER BY date ASC) AS temp_partition
    FROM rates
    WHERE NOT NULLIF(adjclose, 0) IS NULL -- throw out rows without proper fx rate

  ), all_dates AS (

    SELECT date FROM {{ ref('gemma_dates') }} ORDER BY 1

  ), add_missing_dates AS (

    SELECT
        d.date
      , rn.currency
      , FIRST_VALUE(rn.fx_rate_usd) OVER (
          PARTITION BY rn.currency, rn.temp_partition ORDER BY rn.date ASC
        ) AS fx_rate_usd
    FROM all_dates d
      LEFT JOIN remove_nulls rn
        ON d.date BETWEEN rn.date AND IFNULL(DATEADD(day,-1, rn.next_date), rn.date)

  ), add_usd AS (

    SELECT * FROM add_missing_dates
    UNION ALL
    SELECT
        date
      , 'USD'
      , 1
    FROM all_dates AS mm

  ), base_currency AS (

    SELECT * FROM add_usd
    WHERE currency = '{{ var("gemma:fx:base_currency")|upper() }}'

  ), final AS (

    SELECT
        au.date
      , au.currency AS fx_currency
      , bc.currency AS base_currency
      , bc.fx_rate_usd / au.fx_rate_usd AS fx_rate
    FROM add_usd AS au
      LEFT JOIN base_currency AS bc
        ON bc.date = au.date

  )

  SELECT * FROM final
  ORDER BY date DESC, fx_currency ASC

{% elif var("gemma:fx:enabled") %}

  {% do exceptions.raise_compiler_error(target.type ~ " is not supported in gemma_fx model") %}

{% endif %}
