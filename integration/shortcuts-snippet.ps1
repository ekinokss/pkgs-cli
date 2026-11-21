# Package Management section for lib\shortcuts.ps1.
# Requires the surrounding Show-Section / Show-Shortcut helpers.

Show-Section 'Package Management'
Show-Shortcut 'pkgs'                  'Home screen: updates, installed, search, protection'
Show-Shortcut 'pkgs outdated'         'Readable update table with types and status'
Show-Shortcut 'pkgs installed'        'Installed inventory with manager/type'
Show-Shortcut 'pkgs managers'         'Manager / capability matrix'
Show-Shortcut 'pkgs upgrade <mgr:id>' 'Preview then upgrade one package'
Show-Shortcut 'pkgs install <mgr:id>' 'Preview then install one package'
Show-Shortcut 'pkgs remove <mgr:id>'  'Preview then uninstall one package'
Show-Shortcut 'pkgs pin <mgr:id>'     'Native pin/hold where supported'
Show-Shortcut 'pkgs ignore <mgr:id>'  'Local protection from updates'
Show-Shortcut 'pkgs howto'            'Package management guide'
Show-Shortcut 'Enter / Esc'           'In pkgs: open action / go back'
Show-Shortcut 'Tab / Ctrl-/'          'In pkgs: multi-select / preview'
Show-Shortcut 'Alt-Up/Down'           'In pkgs: scroll the details preview'
