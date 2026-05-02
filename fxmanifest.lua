game 'rdr3'
fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

author 'kam'
description 'Armoured Wagon Robbery'
version '1.0.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    'server.lua',
}

client_scripts {
    'client.lua',
}

dependency {
    'vorp_core',
    'vorp_inventory',
    'syn_minigame',
}
