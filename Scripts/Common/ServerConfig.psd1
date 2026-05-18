# Scripts/Common/ServerConfig.psd1
# Central registry of all infrastructure endpoints, server names, and connection strings.
# Credentials (API keys, passwords) are stored separately as .credentials.clixml files.
@{
    # ── Elasticsearch ──────────────────────────────────────────────────────────────
    Elasticsearch = @{
        OrchestraSearchUrl        = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search'
        SubscriptionFlowSearchUrl = 'https://es-obs.apps.zeus.wien.at/logs-subscriptionflow.journals*/_search'
    }

    # ── SQL Server ─────────────────────────────────────────────────────────────────
    SqlServer = @{
        Adm = @{
            Connection = 'idesql.wienkav.at,1433'
            Database   = 'ADM'
            Environment = 'production'
        }
        Medarchiv = @{
            Connection = 'MedarchivSql.wienkav.at,1433'
            Environment = 'production'
            # Database resolved per Anstalt — see MedarchivDatabases below
        }
        ElasticData = @{
            Connection = 'evolux.wienkav.at'
            Database   = 'ElasticData'
            Environment = 'testing'
        }
    }

    # ── Orchestra shared paths (identical on every server) ─────────────────────────
    OrchestraReinjectPath      = '/Orchestra/dfd2a092-4004-4805-9e34-d40947fd218d/2050848662882009363/ITI_SUBFL_ch_Nachrichten_erneut_einbringen'
    OrchestraDeploymentApiBase = '/OrchDyn'

    # ── Orchestra servers ──────────────────────────────────────────────────────────
    # BaseUrl     : scheme + host + port, no trailing slash
    # Environment : production | staging | testing | development
    #               Used for output coloring, filtering, and server identification.
    OrchestraTargets = @{
        'dev01-wsk'  = @{ BaseUrl = 'https://dev01.esb.wienkav.at:8443';  Environment = 'development' }
        'test01-wsk' = @{ BaseUrl = 'https://test01.esb.wienkav.at:8443'; Environment = 'testing'     }
        'test02-wsk' = @{ BaseUrl = 'https://test02.esb.wienkav.at:8543'; Environment = 'testing'     }
        'test03-wsk' = @{ BaseUrl = 'https://test03.esb.wienkav.at:8443'; Environment = 'testing'     }
        'test04-wsk' = @{ BaseUrl = 'https://test04.esb.wienkav.at:8543'; Environment = 'testing'     }
        'mig01-wsk'  = @{ BaseUrl = 'https://mig01.esb.wienkav.at:8443';  Environment = 'staging'     }
        'mig02-wsk'  = @{ BaseUrl = 'https://mig02.esb.wienkav.at:8543';  Environment = 'staging'     }
        'mig03-wsk'  = @{ BaseUrl = 'https://mig03.esb.wienkav.at:8443';  Environment = 'staging'     }
        'mig04-wsk'  = @{ BaseUrl = 'https://mig04.esb.wienkav.at:8543';  Environment = 'staging'     }
        'prod01-wsk' = @{ BaseUrl = 'https://prod01.esb.wienkav.at:8443'; Environment = 'production'  }
        'prod02-wsk' = @{ BaseUrl = 'https://prod02.esb.wienkav.at:8543'; Environment = 'production'  }
        'prod03-wsk' = @{ BaseUrl = 'https://prod03.esb.wienkav.at:8443'; Environment = 'production'  }
        'prod04-wsk' = @{ BaseUrl = 'https://prod04.esb.wienkav.at:8543'; Environment = 'production'  }
        'ESB-T'      = @{ BaseUrl = 'https://esbt.wien.gv.at:8543';       Environment = 'testing'     }
        'ESB-Q'      = @{ BaseUrl = 'http://esbq.wien.gv.at:8019';        Environment = 'staging'     }
        'ESB-PROD-B' = @{ BaseUrl = 'http://esbprodb.wien.gv.at:8119';    Environment = 'production'  }
    }

    # ── PatAuskunft service (environment → base URL) ───────────────────────────────
    PatAuskunft = @{
        production  = 'https://dg-patauskunft.wienkav.at/service/'
        staging     = 'https://abndg-patauskunft.wienkav.at/service/'
        testing     = 'https://epadg-patauskunft.wienkav.at/service/'
        development = 'https://epadg-patauskunft.wienkav.at/service/'
    }

    # ── Medarchiv Anstalt → database mapping (replaces DatabaseMappings.csv) ───────
    # DatabaseName : SQL Server database name
    # ElasticName  : BK.SUBFL_sourcedb filter value in Elasticsearch
    MedarchivDatabases = @{
        '3570' = @{ DatabaseName = 'ma_index_szy';  ElasticName = 'ee_ma_index_3570';  Environment = 'production' }
        '3578' = @{ DatabaseName = 'ma_index_tzy';  ElasticName = 'ee_ma_index_3578';  Environment = 'production' }
        '9099' = @{ DatabaseName = 'ma_index_gzf';  ElasticName = 'ee_ma_index_9099';  Environment = 'production' }
        '9103' = @{ DatabaseName = 'ma_index_kfj';  ElasticName = 'ee_ma_index_9103';  Environment = 'production' }
        '9163' = @{ DatabaseName = 'ma_index_khl';  ElasticName = 'ee_ma_index_9163';  Environment = 'production' }
        '9173' = @{ DatabaseName = 'ma_index_kar';  ElasticName = 'ee_ma_index_9173';  Environment = 'production' }
        '9213' = @{ DatabaseName = 'ma_index_wil';  ElasticName = 'ee_ma_index_9213';  Environment = 'production' }
        '9249' = @{ DatabaseName = 'ma_index_gzb';  ElasticName = 'ee_ma_index_9249';  Environment = 'production' }
        '9359' = @{ DatabaseName = 'ma_index_9359'; ElasticName = 'ee_ma_index_9359';  Environment = 'production' }
        '9369' = @{ DatabaseName = 'ma_index_9369'; ElasticName = 'ee_ma_index_9369';  Environment = 'production' }
        '9399' = @{ DatabaseName = 'ma_index_gzl';  ElasticName = 'ee_ma_index_9399';  Environment = 'production' }
        '9449' = @{ DatabaseName = 'ma_index_9449'; ElasticName = 'ee_ma_index_9449';  Environment = 'production' }
        '9479' = @{ DatabaseName = 'ma_index_9479'; ElasticName = 'ee_ma_index_9479';  Environment = 'production' }
        '9563' = @{ DatabaseName = 'ma_index_smz';  ElasticName = 'ee_ma_index_9563';  Environment = 'production' }
        '9569' = @{ DatabaseName = 'ma_index_gzd';  ElasticName = 'ee_ma_index_9569';  Environment = 'production' }
        '9718' = @{ DatabaseName = 'ma_index_ows';  ElasticName = 'ee_ma_index_9718';  Environment = 'production' }
        '9763' = @{ DatabaseName = 'ma_index_9763'; ElasticName = 'ee_ma_index_9763';  Environment = 'production' }
        '9809' = @{ DatabaseName = 'ma_index_9809'; ElasticName = 'ee_ma_index_9809';  Environment = 'production' }
    }
}
