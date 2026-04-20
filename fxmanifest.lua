-- ================================================================
--  STAGECOACH ROBBERY  |  fxmanifest.lua
--  VORP Core 2025/2026  |  RedM / CFX
-- ================================================================

fx_version 'cerulean'
game 'rdr3'

name        'stagecoach_robbery'
description 'Stagecoach robbery mission — VORP Core framework'
author      'unknown'
version     '1.0.0'

shared_scripts {
    'config.lua',
}

client_scripts {
    'client.lua',
}

server_scripts {
    'server.lua',
}

dependencies {
    'vorp_core',
    'vorp_inventory',
}
