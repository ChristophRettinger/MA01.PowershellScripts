/*
    Missing process checks for dbo.ElasticData.

    Input rows:
      - MSGID is set
      - BK_SUBFL_subid is empty/null

    Output rows:
      - MSGID is set
      - BK_SUBFL_subid is set

    Expected outputs per MSGID are read from BK_SUBFL_subid_list_xml.
*/

;WITH InputRows AS
(
    SELECT DISTINCT
        ed.MSGID,
        ed.BK_SUBFL_subid_list,
        ed.BK_SUBFL_subid_list_xml
    FROM dbo.ElasticData ed
    WHERE ed.MSGID IS NOT NULL
      AND LTRIM(RTRIM(ed.MSGID)) <> ''
      AND (ed.BK_SUBFL_subid IS NULL OR LTRIM(RTRIM(ed.BK_SUBFL_subid)) = '')
),
ExpectedOutput AS
(
    SELECT
        i.MSGID,
        expectedSubId = LTRIM(RTRIM(x.value('(.)[1]', 'nvarchar(200)')))
    FROM InputRows i
    CROSS APPLY i.BK_SUBFL_subid_list_xml.nodes('/subids/subid') AS s(x)
),
ActualOutput AS
(
    SELECT DISTINCT
        ed.MSGID,
        actualSubId = LTRIM(RTRIM(ed.BK_SUBFL_subid))
    FROM dbo.ElasticData ed
    WHERE ed.MSGID IS NOT NULL
      AND LTRIM(RTRIM(ed.MSGID)) <> ''
      AND ed.BK_SUBFL_subid IS NOT NULL
      AND LTRIM(RTRIM(ed.BK_SUBFL_subid)) <> ''
)

-- a) Missing all outputs: input exists, but there is no output row at all for the MSGID.
SELECT
    i.MSGID,
    i.BK_SUBFL_subid_list AS expected_subid_list
FROM InputRows i
LEFT JOIN ActualOutput a
    ON a.MSGID = i.MSGID
WHERE a.MSGID IS NULL
ORDER BY i.MSGID;

-- b) Missing some outputs: outputs exist, but not all expected subids are present.
SELECT
    s.MSGID,
    s.expected_subid_list,
    s.missing_subids,
    s.existing_output_count,
    s.expected_output_count
FROM InputRows i
CROSS APPLY
(
    SELECT
        i.MSGID,
        i.BK_SUBFL_subid_list AS expected_subid_list,
        missing_subids = STUFF
        (
            (
                SELECT
                    ',' + e2.expectedSubId
                FROM
                (
                    SELECT DISTINCT
                        e.expectedSubId
                    FROM ExpectedOutput e
                    WHERE e.MSGID = i.MSGID
                      AND e.expectedSubId <> ''
                ) e2
                LEFT JOIN
                (
                    SELECT DISTINCT
                        a2.actualSubId
                    FROM ActualOutput a2
                    WHERE a2.MSGID = i.MSGID
                ) a3
                    ON a3.actualSubId = e2.expectedSubId
                WHERE a3.actualSubId IS NULL
                ORDER BY e2.expectedSubId
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'),
            1,
            1,
            ''
        ),
        existing_output_count =
        (
            SELECT COUNT(*)
            FROM
            (
                SELECT DISTINCT
                    a4.actualSubId
                FROM ActualOutput a4
                INNER JOIN
                (
                    SELECT DISTINCT
                        e3.expectedSubId
                    FROM ExpectedOutput e3
                    WHERE e3.MSGID = i.MSGID
                      AND e3.expectedSubId <> ''
                ) e4
                    ON e4.expectedSubId = a4.actualSubId
                WHERE a4.MSGID = i.MSGID
            ) x
        ),
        expected_output_count =
        (
            SELECT COUNT(*)
            FROM
            (
                SELECT DISTINCT
                    e5.expectedSubId
                FROM ExpectedOutput e5
                WHERE e5.MSGID = i.MSGID
                  AND e5.expectedSubId <> ''
            ) y
        )
) s
WHERE s.existing_output_count < s.expected_output_count
  AND EXISTS
  (
      SELECT 1
      FROM ActualOutput a
      WHERE a.MSGID = i.MSGID
  )
ORDER BY s.MSGID;
