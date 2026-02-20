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
    i.MSGID,
    i.BK_SUBFL_subid_list AS expected_subid_list,
    missing_subids = STRING_AGG(CASE WHEN a2.actualSubId IS NULL THEN e.expectedSubId END, ',') WITHIN GROUP (ORDER BY e.expectedSubId),
    existing_output_count = COUNT(DISTINCT a2.actualSubId),
    expected_output_count = COUNT(DISTINCT e.expectedSubId)
FROM InputRows i
INNER JOIN ActualOutput a
    ON a.MSGID = i.MSGID
INNER JOIN ExpectedOutput e
    ON e.MSGID = i.MSGID
LEFT JOIN ActualOutput a2
    ON a2.MSGID = e.MSGID
   AND a2.actualSubId = e.expectedSubId
WHERE e.expectedSubId <> ''
GROUP BY
    i.MSGID,
    i.BK_SUBFL_subid_list
HAVING COUNT(DISTINCT a2.actualSubId) < COUNT(DISTINCT e.expectedSubId)
ORDER BY i.MSGID;
