use strict;
use warnings;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use File::Path qw(remove_tree);
use File::Copy;

# subs for loading available conda dependency families
# for speed and efficiency, use mamba to create conda environments

# TODO: at present, does not yet handle pip installations, i.e.
# dependencies:
#     - pip:
#         - abc=0.0.1
# will it be necessary?  always prefer conda packages if available

use vars qw(@args $environmentsDir $config %conda %optionArrays);

#------------------------------------------------------------------------------
# set the program dependencies list for a pipeline action from its config
#------------------------------------------------------------------------------
sub parseAllDependencies {
    my ($subjectAction) = @_;
    
    # determine if action has dependencies
    %conda = (channels => [], dependencies => []);
    my $cmd = getCmdHash($subjectAction) or return;
    $$cmd{condaFamilies} or return;
    $$cmd{condaFamilies}[0] or return;
    
    # collect the conda family dependencies, in precedence order
    foreach my $family(@{$$cmd{condaFamilies}}){
        my $found;         
        foreach my $yml(loadSharedConda($family),
                        loadPipelineConda($family)){
            $yml or next;
            $found++;
            $$yml{channels}     and push @{$conda{channels}},     @{$$yml{channels}};
            $$yml{dependencies} and push @{$conda{dependencies}}, @{$$yml{dependencies}};            
        }
        $found or throwError("pipeline configuration error\ncould not find conda family:\n    $family");
    }
    
    # purge duplicate entries by dependency (not version)
    foreach my $key(qw(channels dependencies)){
        my %seen;
        my @out;
        foreach my $value(reverse(@{$conda{$key}})){
            my ($item, $version) = split('=', $value, 2);
            $seen{$item} and next;
            $seen{$item}++;            
            unshift @out, $value;  
        }
        @{$conda{$key}} = @out;
    }
}
sub loadSharedConda { # first load environment configs from shared files
    my ($family_) = @_;
    my ($family, $version) = $family_ =~ m/(.+)-(\d+\.\d+)/ ? ($1, $2) : ($family_);
    my $dir = getSharedFile($environmentsDir, $family, 'environment'); # either shared or external
    $dir or return;
    -d $dir or return;
    my $prefix = "$dir/$family";
    if (!$version) {
        my @files = glob("$prefix-*.yml");
        my @versions = sort { $b <=> $a } map { $_ =~ m/$prefix-(.+)\.yml/; $1 } @files;
        $version = $versions[0];
    }
    my $file = "$prefix-$version.yml";
    -e $file or return;
    loadYamlFile($file);
}
sub loadPipelineConda { # then load environment configs from pipeline config (overrides shared)
    my ($family) = @_;
    $$config{condaFamilies} or return;
    $$config{condaFamilies}{$family};
}

#------------------------------------------------------------------------------
# get the path to an environment directory, based on either:
#    - an environment name forced by config key 'action:<action>:environment', or
#    - an identifying hash for a standardized, sharable environment (not pipeline specific)
#------------------------------------------------------------------------------
sub getCondaPaths {
    my ($configYml, $subjectAction) = @_;
    
    # check the path where environments are installed
    my $baseDir = "$ENV{MDI_DIR}/environments";
    -d $baseDir or throwError("conda directory does not exist:\n    $baseDir");
    
    # establish the proper name for the environment
    my $cmd = getCmdHash($subjectAction);
    my ($envName, $envType) = ($$cmd{environment});
    if($envName and ref($envName) eq 'ARRAY'){
        # a name forced by pipeline.yml, especially useful during pipeline developement
        $envName = $$envName[0];
        $envType = "named";
        $envName eq "mamba" and throwError(
            "bad environment name\n'mamba' is reserved for the MDI mamba installation"
        );
    } else {
        # assemble an MD5 hash for a standardized, sharable environment
        my @conda;
        push @conda, ('channels:', @{$conda{channels}}); # channel order is important, do not reorder
        push @conda, ('dependencies:', sort @{$conda{dependencies}});
        my $digest = md5_hex(join(" ", @conda));
        $envName = substr($digest, 0, 10); # shorten it for a bit nicer display
        $envType = "sharable";
    }

    # set environment paths
    my $envDir   = "$baseDir/$envName";
    my $initFile = "$baseDir/$envName.yml"; # used to create the environment
    my $showFile = "$envDir/$envName.yml";  # permanent store to show what was created
    
    # locate the script that must be sourced to allow 'conda activate' to be called from scripts
    # see: https://github.com/conda/conda/issues/7980
    my $profileScript = applyVariablesToYamlValue($$configYml{conda}{'profile-script'}[0], \%ENV);
    if(!$profileScript or $profileScript eq 'null'){
        my $condaBasePath = qx/conda info --base/;
        chomp $condaBasePath;
        $profileScript = "$condaBasePath/etc/profile.d/conda.sh";
    }
    
    # determine if the server requires us to load conda (if not, it must be always available)
    my $loadCommand = applyVariablesToYamlValue($$configYml{conda}{'load-command'}[0], \%ENV);
    if(!$loadCommand or $loadCommand eq 'null'){
        $loadCommand = "# using system conda";
    }
    
    # return our conda details
    {
        baseDir       => $baseDir,
        dir           => $envDir,
        initFile      => $initFile,
        showFile      => $showFile,
        name          => $envName,
        type          => $envType,
        profileScript => $profileScript,
        loadCommand   => $loadCommand
    }
}

#------------------------------------------------------------------------------
# if missing, install mamba (which is then used as a drop-in replacement for conda)
# https://github.com/mamba-org/mamba
#------------------------------------------------------------------------------
# 'checkForMamba' creates a conda environment containing only mamba (only run once per server)
#     conda create --prefix $MDI_DIR/environments/mamba --channel conda-forge --yes mamba
# 'createCondaEnvironment' then uses mamba to create conda environments for pipelines
#     conda activate $MDI_DIR/environments/mamba
#     mamba create --prefix $MDI_DIR/environments/xxxx --file xxxx
#     conda deactivate
# finally, conda (not mamba) is used to activate the environment for a pipeline job
#     conda activate $MDI_DIR/xxxx
#------------------------------------------------------------------------------
sub checkForMamba { 
    my ($cnd) = @_;
    my $mambaDir = "$ENV{MDI_DIR}/environments/mamba";
    -e $mambaDir and return $mambaDir;
    my $bash =
"bash -c '
$$cnd{loadCommand}
source $$cnd{profileScript}
conda create --prefix $mambaDir --channel conda-forge --yes mamba
'";
    print "installing mamba\n";
    print "\n$bash\n";
    if(system($bash)){
        remove_tree $mambaDir;
        throwError("mamba installation failed");
    }
    $mambaDir;
}

#------------------------------------------------------------------------------
# if missing, create conda environment(s)
# if present but named and out-of-date, update 
#------------------------------------------------------------------------------
sub showCreateCondaEnvironments {
    my ($create, $force, $noMamba) = @_;
    my $cmds = $$config{actions}; 
    my @orderedActions = sort { $$cmds{$a}{order}[0] <=> $$cmds{$b}{order}[0] } keys %$cmds;
    my @argsBuffer = @args;
    foreach my $subjectAction(@orderedActions){
        $$cmds{$subjectAction}{universal}[0] and next;
        my $cmd = getCmdHash($subjectAction);
        loadActionOptions($cmd);
        my $configYml = assembleCompositeConfig($cmd, $subjectAction);
        setOptionsFromConfigComposite($configYml, $subjectAction);
        parseAllDependencies($subjectAction);
        my $cnd = getCondaPaths($configYml, $subjectAction);
        print "---------------------------------\n";
        print "conda environment for: $$config{pipeline}{name}[0] $subjectAction\n";
        print "$$cnd{dir}\n";
        if ($create) {
            createCondaEnvironment($cnd, 1, $force, $noMamba);            
        } else {
            if (-e $$cnd{showFile}) {
                print "$$cnd{showFile}\n";
                print slurpFile($$cnd{showFile});               
            } else {
                print "not created yet\n";
            }
        }
        print "---------------------------------\n";
        @args = @argsBuffer; # ensure that assembleCompositeConfig runs properly each time
    }
}
sub createCondaEnvironment { # handles both create and update actions
    my ($cnd, $showExists, $force, $noMamba) = @_;

    # determine how to handle this call based on environment type
    my ($envExists, $condaAction, $outYml) = (-d $$cnd{dir});
    if($$cnd{type} eq 'named'){ # name forced by developer
        if($envExists){
            $outYml = getCondaEnvironmentYml(); # check whether update is needed
            my $inYml = slurpFile( $$cnd{showFile} );
            if($outYml eq $inYml){
                $showExists and print "environment exists and is up to date\n";
                return;  
            }
            $condaAction = 'update --prune';
        } else {
            $condaAction = 'create';         
        }
    } else { # automated name suitable for generalized environment sharing
        if($envExists){
            $showExists and print "environment already exists\n";
            return; # hashed name demands that the environment has all depedencies             
        }
        $condaAction = 'create';
    }

    # get permission to create/update the environment   
    my $isCreate = $condaAction eq 'create';
    my $msg = $isCreate ? 
        "Missing conda environment, it will be created." : 
        "Conda environment exists, it will be updated.";
    getPermission($msg, $force) or 
        throwError("Cannot proceed without the proper conda environment.");

    # write the required environment.yml file; moved into environment directory on successful create/update
    $outYml or $outYml = getCondaEnvironmentYml();
    open my $outH, ">", $$cnd{initFile} or throwError("could not open:\n    $$cnd{initFile}\n$!");
    print $outH $outYml;
    close $outH;

    # Singularity container build always uses conda, not mamba
    my $bash;
    my $condaCommand = "env $condaAction --prefix $$cnd{dir} --file $$cnd{initFile}";
    if($ENV{IS_CONTAINER_BUILD}){
        $bash = 
"bash -c 'conda $condaCommand'";

    # allow use of conda-only, i.e., bypass mamba, on systems where mamba is problematic
    } elsif($noMamba){
        $bash = 
"bash -c '
$$cnd{loadCommand}
source $$cnd{profileScript}
conda $condaCommand
'";
    
    # default is to use Mamba to speed subsequent environment creation
    } else {
        # make sure mamba is available, install on first use
        my $mambaDir = checkForMamba($cnd);
        
        # create the environment
        $bash =
"bash -c '
$$cnd{loadCommand}
source $$cnd{profileScript}
conda activate $mambaDir
mamba $condaCommand
conda deactivate
'";
    }

    # execute the conda/mamba environment creation script
    print "executing command sequence: $bash\n";
    if(system($bash)){
        $isCreate and remove_tree $$cnd{dir};
        unlink $$cnd{initFile}; 
        throwError("conda create/update failed");
    }
    move($$cnd{initFile}, $$cnd{showFile});
}
sub getCondaEnvironmentYml {
    my $indent = "    ";
    my $yml = "---\n"; # do NOT put name or prefix in file (should work, but doesn't)
    foreach my $key(qw(channels dependencies)){
        ($conda{$key} and ref($conda{$key}) eq 'ARRAY' and @{$conda{$key}}) or next;
        $yml .= "$key:\n";
        $yml .= join("\n", map { "$indent- $_" } @{$conda{$key}})."\n";
    }
    $yml .= "\n";
}

1;
