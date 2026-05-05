#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);

#========================================================================
# 'server.pl' launches the web server to use interactive Stage 2 apps
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
my ($serverCmd, $singularityLoad);
my $silently = "> /dev/null 2>&1";
my $mdiCommand = 'server';
my %serverCmds = map { $_ => 1 } qw(run develop remote node);
my $serverCmds = join(", ", keys %serverCmds);
my $MDI_CENTRIC   = "mdi-centric";
my $SUITE_CENTRIC = "suite-centric";
my $suiteMode     = $MDI_CENTRIC;
my $suiteName     = "";
my $suiteDir      = "";
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub mdiServer { 
    ############################
    # $options{'runtime'} = "conda";

    # remove trailing slash(es) on paths for consistent handling
    $ENV{MDI_DIR} =~ m|(.+)/+$| and $ENV{MDI_DIR} = $1; 
    $options{'host-dir'} and $options{'host-dir'} =~ m|(.+)/+$| and $options{'host-dir'} = $1; 
    $options{'data-dir'} and $options{'data-dir'} =~ m|(.+)/+$| and $options{'data-dir'} = $1; 

    # check the requested server command
    $serverCmd = $options{'server-command'};
    $serverCmds{$serverCmd} or 
        throwError("bad value for option '--server-command': $serverCmd\n"."expected one of: $serverCmds", $mdiCommand);

    # short-circuit a request for running server via system R, regardless of Singularity support
    my $runtime = $options{'runtime'};
    $runtime or $runtime = 'auto';
    ($runtime eq 'direct' or $runtime eq 'conda') and return launchServerDirect();

    # determine the MDI installation type
    # only suite-centric installations support containerized apps servers
    my $suiteConfigFile = "$ENV{MDI_DIR}/../_config.yml";
    $ENV{SUITE_MODE} = $suiteMode;
    $ENV{SUITE_NAME} = "";
    if(-f $suiteConfigFile){
        $suiteMode = $SUITE_CENTRIC;
        $suiteName = basename(dirname($ENV{MDI_DIR}));
        $suiteDir = "$ENV{MDI_DIR}/suites/definitive/$suiteName"; # only definitive repos have semantic version tags
        $ENV{SUITE_MODE} = $suiteMode;
        $ENV{SUITE_NAME} = $suiteName;
    }
    my $isSuiteCentric = $suiteMode eq $SUITE_CENTRIC;
    
    # determine whether system supports Singularity
    $singularityLoad = getSingularityLoadCommand();

    # determine if and how the MDI installation supports Singularity
    my ($containerConfig, $suiteSupportsContainers);
    if ($isSuiteCentric){
        my $ymlFile = "$suiteDir/_config.yml";
        my $yamls = loadYamlFromString( slurpFile($ymlFile) );
        $containerConfig = $$yamls{parsed}[0]{container};
        $suiteSupportsContainers = suiteSupportsAppContainer($containerConfig);
    }

    # validate a request for running server via Singularity, without possibility for system fallback
    if($runtime eq 'container' or $runtime eq 'singularity'){
        $isSuiteCentric or 
            throwError("only suite-centric installations support containerized apps servers", $mdiCommand);
        $singularityLoad or 
            throwError("--runtime '$runtime' requires Singularity on system or via config/singularity.yml >> load-command", $mdiCommand);
        $suiteSupportsContainers or 
            throwError("--runtime '$runtime' requires container support from the tool suite", $mdiCommand);
    } 

    # dispatch the launch request to the proper handler
    if($isSuiteCentric and $singularityLoad and $suiteSupportsContainers){
        launchServerSuiteContainer($containerConfig);
    } else {
        launchServerDirect(); # runtime=auto, but no valid means of container support
    }
}
#========================================================================

#========================================================================
# process different paths to launching the server
#------------------------------------------------------------------------

# launch directly via system R
sub launchServerDirect {
    my $dataDir = $options{'data-dir'} ? ", dataDir = \"".$options{'data-dir'}."\"" : "";
    my $hostDir = $options{'host-dir'} ? ", hostDir = \"".$options{'host-dir'}."\"" : "";
    my $rLoadCommand = $ENV{R_LOAD_COMMAND} || "echo $silently";
    my $R_SCRIPT = qx/$rLoadCommand; command -v Rscript/;
    chomp $R_SCRIPT;
    $R_SCRIPT or throwError(
        "FATAL: R program target Rscript not found\n". 
        "Please install or load R as required on your system or server,\n".
        "    e.g., `module load R/0.0.0`.\n".
        'server');
    my $R_VERSION = qx|$rLoadCommand; Rscript --version|;
    $R_VERSION =~ m/version\s+(\d+\.\d+)/ and $R_VERSION =$1;
    my $libsPath = "$ENV{MDI_DIR}/library";
    my $R_LIBRARY = "$libsPath/R-$R_VERSION"; # mdi-manager R package installed here
    -d $R_LIBRARY or throwError(
        "FATAL: R library directory for R version $R_VERSION not found:\n". 
        "    $R_LIBRARY\n".
        "Have you installed the MDI or tool suite for this R version?\n",
        'server');
    my $BC_LIBRARY = qx|ls -1d $libsPath/R-$R_VERSION\_BC-*|;
    chomp $BC_LIBRARY;
    $BC_LIBRARY or throwError(
        "FATAL: Bioconductor library for R version $R_VERSION not found.\n". 
        "Have you installed the MDI or tool suite for this R version?\n",
        'server');
    $BC_LIBRARY =~ m/_BC-(\d+.\d+)$/ or throwError(
        "FATAL: Bioconductor library directory has invalid name format:\n". 
        "    $BC_LIBRARY\n".
        'server');
    $ENV{BIOCONDUCTOR_RELEASE} = $1;
    my $port = $options{'port'} || 3838;
    my $load_libGit2 = getLibgit2LoadCommand();
    exec "$load_libGit2; $rLoadCommand; Rscript -e '.libPaths(\"$R_LIBRARY\"); mdi::$serverCmd(mdiDir = \"$ENV{MDI_DIR}\", port = $port $dataDir $hostDir)'";
}

# launch via Singularity with suite-level container
sub launchServerSuiteContainer {
    my ($containerConfig) = @_;
    my $imageFile = getTargetAppsImageFile($containerConfig);
    launchServerContainer($imageFile);
} 

# common container run action
sub launchServerContainer {
    my ($imageFile) = @_;
    -f $imageFile or throwError("image file not found\n    $imageFile", 'server');
    my $srvActiveMdiDir  = "/srv/active/mdi";
    my $srvActiveDataDir = "$srvActiveMdiDir/data";
    my $dataDir = $options{'data-dir'} || $srvActiveDataDir; # host directory not applicable to the running containerized server
    uc($dataDir) eq "NULL" and $dataDir = $srvActiveDataDir;
    $dataDir =~ m|^$ENV{MDI_DIR}| and $dataDir = $srvActiveDataDir; # prevent nested binds, if within MDI_DIR just use the standard active data directory
    my $bind = "--bind $ENV{MDI_DIR}:$srvActiveMdiDir";
    my @bound = ($ENV{MDI_DIR});
    my @toBind = $dataDir eq $srvActiveDataDir ? () : ($dataDir);
    addStage2BindMounts(\$bind, \@bound, \@toBind); # add user bind paths from config/stage2-apps.yml
    my $singularityCommand = $ENV{SINGULARITY_COMMAND} || "run"; # for debugging, typically set to "shell"
    my $port = $options{'port'} || 3838;
    $ENV{CALLER_MDI_DIR} = $ENV{MDI_DIR}; # remember the MDI_DIR for display in apps that replaces /srv/active/mdi with the bound path
    exec "$singularityLoad; singularity $singularityCommand $bind $imageFile run_apps $serverCmd $dataDir $port";
}
#========================================================================

#========================================================================
# determine how to load libgit2, if available (if not the installer used git2r v0.33)
#------------------------------------------------------------------------
sub getLibgit2LoadCommand {
    my $command = "echo $silently";
    checkForLibgit2($command) and return $command; 
    $command = "module load libgit2 $silently";
    checkForLibgit2($command) and return $command; 
    $command = "module load git $silently";
    checkForLibgit2($command) and return $command; 
    "echo $silently" # libgit2 could not be loaded, expect fallback version 0.33 of git2r to have been installed
}
sub checkForLibgit2 {
    my ($command) = @_;
    !system("$command; pkg-config --exists --atleast-version 1.0 libgit2");
}
#========================================================================

#========================================================================
# discover Singularity on the system, if available
#------------------------------------------------------------------------
sub getSingularityLoadCommand {

    # first, see if singularity or apptainer command is already present and ready
    # NB: apptainer installations provide alias `singularity` to `apptainer`
    #     but commands report logs info as `apptainer`
    my $command = "echo $silently";
    checkForSingularity($command) and return $command; 
    
    # if not, attempt to use load-command from singularity.yml
    my $mdiDir = ($options{'host-dir'} and $options{'host-dir'} ne "NULL") ? $options{'host-dir'} : $ENV{MDI_DIR};
    my $ymlFile = "$mdiDir/config/singularity.yml";
    if(-e $ymlFile){
        my $yamls = loadYamlFromString( slurpFile($ymlFile) );
        $command = $$yamls{parsed}[0]{'load-command'};
        if($command and $$command[0]){
            $command = "$$command[0] $silently";
            checkForSingularity($command) and return $command;
        }
    }

    # if not, attempt to use "module load singularity" as the default singularity load command
    $command = "module load singularity";
    checkForSingularity($command) and return $command;

    # no success
    undef;
}
sub checkForSingularity { # return TRUE if a proper singularity exists in system PATH after executing $command
    my ($command) = @_;
    system("$command; singularity --version $silently") and return; # command did not exist, system threw an error
    my $version = qx|$command; singularity --version|;
    $version =~ m/^(singularity|apptainer).+version.+/; # may fail if not a true singularity target (e.g., on greatlakes)
}
#========================================================================

#========================================================================
# discover modes for apps server container support, if any
#------------------------------------------------------------------------
sub suiteSupportsAppContainer {
    my ($containerConfig) = @_;
    $containerConfig or return; # no container config at all, so no support
    my $supported = $$containerConfig{supported} or return;
    my $stages    = $$containerConfig{stages} or return;
    my $hasApps   = $$stages{apps} or return;
    $$supported[0] and $$hasApps[0];
}
#========================================================================

#========================================================================
# get the requested/latest container version available
#------------------------------------------------------------------------
sub getTargetAppsImageFile {
    my ($containerConfig) = @_;
    my $majorMinorVersion = $options{'container-version'} || getSuiteLatestVersion();
    $majorMinorVersion =~ m/^v/ or $majorMinorVersion = "v$majorMinorVersion"; # help user who type "0.0" instead of "v0.0"
    my $imageGlob = lc("$suiteName/$suiteName-apps"); # container names always lower case
    if($options{'host-dir'}){
        my $glob = "$options{'host-dir'}/containers/$imageGlob";
        my $imageFile = "$glob-$majorMinorVersion.sif";
        -f $imageFile and return $imageFile;
    }
    my $glob = "$ENV{MDI_DIR}/containers/$imageGlob";
    my $imageFile = "$glob-$majorMinorVersion.sif";
    ! -f $imageFile and pullSuiteContainer($containerConfig, $imageFile, $majorMinorVersion);
    return $imageFile;
}
sub getSuiteLatestVersion {
    my $tags = qx\cd $suiteDir; git tag -l v*\; # tags that might be semantic version tags on main branch
    chomp $tags;
    my $error = "suite $suiteName does not have any semantic version tags to use to recover container images\n";
    $tags or throwError($error, 'server');
    my @versions;
    foreach my $tag(split("\n", $tags)){
        $tag =~ m/v(\d+)\.(\d+)\.\d+/ or next; # ignore non-semvar tags; note that developer must use v0.0.0 (not 0.0.0)
        $versions[$1][$2]++;
    }
    @versions or throwError($error, 'server');
    my $major = $#versions;
    my $minor = $#{$versions[$major]};
    "v$major.$minor";
}
sub pullSuiteContainer {
    my ($containerConfig, $imageFile, $majorMinorVersion) = @_;
    my $registry  = $$containerConfig{registry}[0];
    my $owner     = $$containerConfig{owner}[0];
    my $packageName = lc "$suiteName-apps"; # container names always lower case
    my $uri = lc("oras://$registry/$owner/$packageName:$majorMinorVersion");
    make_path(dirname($imageFile));
    print STDERR "pulling required container image...\n"; 
    system("$singularityLoad; singularity pull --disable-cache $imageFile $uri") and throwError(
        "container pull failed",
        'server'
    );
}
#========================================================================

#========================================================================
# add a list of user-specified bind mounts to an apps-server container
#------------------------------------------------------------------------
sub addStage2BindMounts {
    my ($bind, $bound, $toBind) = @_;
    my $userConfig = "$ENV{MDI_DIR}/config/stage2-apps.yml"; 
    my $hostConfig = $options{'host-dir'} ? "$options{'host-dir'}/config/stage2-apps.yml" : "__NA__";
    my %seen = map { $_ => 1 } (@$bound, @$toBind);
    foreach my $ymlFile ($userConfig, $hostConfig){
        -f $ymlFile or next;
        my $yamls = loadYamlFromString( slurpFile($ymlFile) );
        my $paths = $$yamls{parsed}[0]{paths} or next;
        ref($paths) eq 'HASH' or next;
        foreach my $name(keys %$paths){
            ref($$paths{$name}) eq 'ARRAY' or next;
            my $dir = $$paths{$name}[0] or next;
            $dir =~ m|(.+)/+$| and $dir = $1; # remove trailing slash(es)
            -d $dir or next;
            $seen{$dir}++ and next;
            push @$toBind, $dir;
            $seen{$dir}++;
        }
    }
    foreach my $dir(sort { length($a) <=> length($b) } @$toBind){
        # skip path that are subpaths of previously bound parent paths
        foreach my $boundDir(@$bound){
            $dir =~ m/^$boundDir/ and next;
        }
        $$bind .= " --bind $dir";
        push @$bound, $dir;
    }
}
#========================================================================

1;
