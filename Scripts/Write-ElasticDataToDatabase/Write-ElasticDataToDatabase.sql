IF OBJECT_ID(N'[dbo].[ElasticData]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[ElasticData]
    (
        [Id] BIGINT IDENTITY(1,1) NOT NULL,
        [MSGID] NVARCHAR(200) NULL,
        [ScenarioName] NVARCHAR(400) NULL,
        [ProcessName] NVARCHAR(400) NULL,
        [ProcesssStarted] NVARCHAR(64) NULL,
        [BK_SUBFL_category] NVARCHAR(200) NULL,
        [BK_SUBFL_subcategory] NVARCHAR(200) NULL,
        [BK_HCMMSGEVENT] NVARCHAR(200) NULL,
        [BK_SUBFL_subid] NVARCHAR(200) NULL,
        [BK_SUBFL_subid_list] NVARCHAR(MAX) NULL,
        [BK_SUBFL_subid_list_xml] XML NULL,
        CONSTRAINT [PK_ElasticData] PRIMARY KEY CLUSTERED ([Id] ASC)
    );
END;
GO

CREATE INDEX [IX_ElasticData_MSGID] ON [dbo].[ElasticData]([MSGID]);
GO

CREATE INDEX [IX_ElasticData_ScenarioName_ProcesssStarted] ON [dbo].[ElasticData]([ScenarioName], [ProcesssStarted]);
GO
