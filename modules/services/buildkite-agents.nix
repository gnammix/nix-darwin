{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.buildkite-agents;
  literalMD = lib.literalMD or (x: lib.literalDocBook "Documentation not rendered. Please upgrade to a newer NixOS with markdown support.");

  mkHookOption = { name, description, example ? null }: {
    inherit name;
    value = mkOption {
      default = null;
      description = description;
      type = types.nullOr types.lines;
    } // (if example == null then {} else { inherit example; });
  };
  mkHookOptions = hooks: listToAttrs (map mkHookOption hooks);

  hooksDir = cfg: let
    mkHookEntry = name: value: ''
      cat > $out/${name} <<'EOF'
      #! ${pkgs.runtimeShell}
      set -e
      ${value}
      EOF
      chmod 755 $out/${name}
    '';
  in pkgs.runCommand "buildkite-agent-hooks" { preferLocalBuild = true; } ''
    mkdir $out
    ${concatStringsSep "\n" (mapAttrsToList mkHookEntry (filterAttrs (n: v: v != null) cfg.hooks))}
  '';

  buildkiteOptions = { name ? "", config, ... }: {
    options = {
      enable = mkOption {
        default = true;
        type = types.bool;
        description = "Whether to enable this buildkite agent";
      };

      package = mkOption {
        default = pkgs.buildkite-agent;
        defaultText = literalExpression "pkgs.buildkite-agent";
        description = "Which buildkite-agent derivation to use";
        type = types.package;
      };

      dataDir = mkOption {
        default = "/var/lib/buildkite-agent-${name}";
        description = "The workdir for the agent";
        type = types.str;
      };

      runtimePackages = mkOption {
        default = [ pkgs.bash pkgs.gnutar pkgs.gzip pkgs.git pkgs.nix ];
        defaultText = literalExpression "[ pkgs.bash pkgs.gnutar pkgs.gzip pkgs.git pkgs.nix ]";
        description = "Add programs to the buildkite-agent environment";
        type = types.listOf (types.either types.package types.path);
      };

      tokenPath = mkOption {
        type = types.path;
        description = ''
          The token from your Buildkite "Agents" page.

          A run-time path to the token file, which is supposed to be provisioned
          outside of Nix store.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "%hostname-${name}-%n";
        description = ''
          The name of the agent as seen in the buildkite dashboard.
        '';
      };

      tags = mkOption {
        type = types.attrsOf (types.either types.str (types.listOf types.str));
        default = {};
        example = { queue = "default"; docker = "true"; ruby2 ="true"; };
        description = ''
          Tags for the agent.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        example = "debug=true";
        description = ''
          Extra lines to be added verbatim to the configuration file.
        '';
      };

      preCommands = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra commands to run before starting buildkite.
        '';
      };

      privateSshKeyPath = mkOption {
        type = types.nullOr types.path;
        default = null;
        ## maximum care is taken so that secrets (ssh keys and the CI token)
        ## don't end up in the Nix store.
        apply = final: if final == null then null else toString final;

        description = ''
          OpenSSH private key

          A run-time path to the key file, which is supposed to be provisioned
          outside of Nix store.
        '';
      };

      hooks = mkHookOptions [
        { name = "checkout";
          description = ''
            The `checkout` hook script will replace the default checkout routine of the
            bootstrap.sh script. You can use this hook to do your own SCM checkout
            behaviour
          ''; }
        { name = "command";
          description = ''
            The `command` hook script will replace the default implementation of running
            the build command.
          ''; }
        { name = "environment";
          description = ''
            The `environment` hook will run before all other commands, and can be used
            to set up secrets, data, etc. Anything exported in hooks will be available
            to the build script.

            Note: the contents of this file will be copied to the world-readable
            Nix store.
          '';
          example = ''
            export SECRET_VAR=`head -1 /run/keys/secret`
          ''; }
        { name = "post-artifact";
          description = ''
            The `post-artifact` hook will run just after artifacts are uploaded
          ''; }
        { name = "post-checkout";
          description = ''
            The `post-checkout` hook will run after the bootstrap script has checked out
            your projects source code.
          ''; }
        { name = "post-command";
          description = ''
            The `post-command` hook will run after the bootstrap script has run your
            build commands
          ''; }
        { name = "pre-artifact";
          description = ''
            The `pre-artifact` hook will run just before artifacts are uploaded
          ''; }
        { name = "pre-checkout";
          description = ''
            The `pre-checkout` hook will run just before your projects source code is
            checked out from your SCM provider
          ''; }
        { name = "pre-command";
          description = ''
            The `pre-command` hook will run just before your build command runs
          ''; }
        { name = "pre-exit";
          description = ''
            The `pre-exit` hook will run just before your build job finishes
          ''; }
      ];

      hooksPath = mkOption {
        type = types.path;
        default = hooksDir config;
        defaultText = literalMD "generated from {option}`services.buildkite-agents.<name>.hooks`";
        description = ''
          Path to the directory storing the hooks.
          Consider using {option}`services.buildkite-agents.<name>.hooks.<name>`
          instead.
        '';
      };

      shell = mkOption {
        type = types.str;
        default = "${pkgs.bash}/bin/bash -e -c";
        defaultText = literalExpression ''"''${pkgs.bash}/bin/bash -e -c"'';
        description = ''
          Command that buildkite-agent 3 will execute when it spawns a shell.
        '';
      };
    };
  };
  enabledAgents = lib.filterAttrs (n: v: v.enable) cfg;
  mapAgents = function: lib.mkMerge (lib.mapAttrsToList function enabledAgents);
in
{
  options.services.buildkite-agents = mkOption {
    type = types.attrsOf (types.submodule buildkiteOptions);
    default = {};
    description = ''
      Attribute set of buildkite agents.
      The attribute key is combined with the hostname and a unique integer to
      create the final agent name. This can be overridden by setting the `name`
      attribute.
    '';
  };

  config.users.users = mapAgents (name: cfg: {
    "buildkite-agent-${name}" = {
      name = "buildkite-agent-${name}";
      home = cfg.dataDir;
      createHome = true;
      description = "Buildkite agent user";
    };
  });
  config.users.groups = mapAgents (name: cfg: {
    "buildkite-agent-${name}" = {};
  });

  config.launchd.daemons = mapAgents (name: cfg: {
    "buildkite-agent-${name}" =
      { path = cfg.runtimePackages ++ [ cfg.package pkgs.coreutils pkgs.darwin.DarwinTools ];
        environment = {
          HOME = cfg.dataDir;
          NIX_REMOTE = "daemon";
          inherit (config.environment.variables) NIX_SSL_CERT_FILE;
        };

        ## NB: maximum care is taken so that secrets (ssh keys and the CI token)
        ##     don't end up in the Nix store.
        script = let
          sshDir = "${cfg.dataDir}/.ssh";
          tagStr =
            name: value:
            if lib.isList value then
              lib.concatStringsSep "," (builtins.map (v: "${name}=${v}") value)
            else
              "${name}=${value}";
          tagsStr = lib.concatStringsSep "," (lib.mapAttrsToList tagStr cfg.tags);
        in
          optionalString (cfg.privateSshKeyPath != null) ''
            mkdir -m 0700 "${sshDir}"
            install -m600 "${toString cfg.privateSshKeyPath}" "${sshDir}/id_rsa"
          '' + ''
            cat > "${cfg.dataDir}/buildkite-agent.cfg" <<EOF
            token="$(cat ${toString cfg.tokenPath})"
            name="${cfg.name}"
            shell="${cfg.shell}"
            tags="${tagsStr}"
            build-path="${cfg.dataDir}/builds"
            hooks-path="${cfg.hooksPath}"
            ${cfg.extraConfig}
            EOF

            ${cfg.preCommands}

            ${cfg.package}/bin/buildkite-agent start --config ${cfg.dataDir}/buildkite-agent.cfg
          '';

        serviceConfig = {
          ProcessType = "Interactive";
          ThrottleInterval = 30;

          # The combination of KeepAlive.NetworkState and WatchPaths
          # will ensure that buildkite-agent is started on boot, but
          # after networking is available (so the hostname is
          # correct).
          RunAtLoad = true;
          WatchPaths = [
            "/etc/resolv.conf"
            "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
          ];

          GroupName = "buildkite-agent-${name}";
          UserName = "buildkite-agent-${name}";
          WorkingDirectory = config.users.users."buildkite-agent-${name}".home;
          StandardErrorPath = "${cfg.dataDir}/buildkite-agent.log";
          StandardOutPath = "${cfg.dataDir}/buildkite-agent.log";
        };
      };
  });

  config.assertions = mapAgents (name: cfg: [
      { assertion = cfg.hooksPath == (hooksDir cfg)  || all (v: v == null) (attrValues cfg.hooks);
        message = ''
          Options `services.buildkite-agents.${name}.hooksPath' and
          `services.buildkite-agents.${name}.hooks.<name>' are mutually exclusive.
        '';
      }
  ]);

  imports = [
    (mkRemovedOptionModule [ "services" "buildkite-agent"] "services.buildkite-agent has been moved to an attribute set at services.buildkite-agents")
  ];
}
