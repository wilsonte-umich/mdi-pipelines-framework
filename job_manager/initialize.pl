#!/usr/bin/perl
use strict;
use warnings;
use Cwd(qw(abs_path));
use File::Basename;

#========================================================================
# 'initialize.pl' sets up job manager for use on a host server system
#========================================================================

#========================================================================
$| = 1;
#------------------------------------------------------------------------
# get the job manager directory and executable name
#------------------------------------------------------------------------
my $jobManagerName = 'mdi';
print STDERR "initializing the '$jobManagerName program' target\n";
my $script = abs_path($0);
$script =~ m|(.*)/initialize.pl$| or die "fatal error: could not establish the job manager directory\n";
my $jobManagerDir = $1;
#------------------------------------------------------------------------
# get paths to perl, bash and /usr/bin/time
#------------------------------------------------------------------------
sub getProgramPath {
    my $path = qx{command -v $_[0] 2>/dev/null | head -n1};
    chomp $path;
    $path =~ s/^\s*//;
    $path =~ s/\s*$//;
    $path;
}
sub requireProgramPath {
    my $path = getProgramPath($_[0]);
    $path or die "fatal error\n"."'$jobManagerName' requires that $_[0] be available on the system\n";
    $path;
}
my $perlPath = requireProgramPath('perl');
my $bashPath = requireProgramPath('bash');
my $timePath = requireProgramPath('/usr/bin/time');
#------------------------------------------------------------------------
# get time version and adjust memory correction accordingly
#------------------------------------------------------------------------
my $timeError = "$timePath is not a valid installation of the GNU time utility\n";
my $timeVersion = qx/$timePath --version 2>&1 | head -n1/; 
chomp $timeVersion;
$timeVersion =~ m/GNU/  or die $timeError;
$timeVersion =~ m/time/ or die $timeError; 
my @tvf = split(/\s+/, $timeVersion);
$timeVersion = $tvf[$#tvf];
$timeVersion or die $timeError;  
$timeVersion eq "UNKNOWN" and $timeVersion = 1.8;   
my $memoryCorrection = $timeVersion > 1.7 ? 1 : 4; # for time <= v1.7, account for the known bug that memory values are 4-times too large
my $memoryMessage = $timeVersion > 1.7 ? "" : "q: !! maxvmem value above is 4-fold too high due to known bug in GNU time utility !!"; 
#------------------------------------------------------------------------
# discover the job scheduler in use on the server
#------------------------------------------------------------------------
my ($qType, $schedulerDir, $submitTarget) = ('','',''); # no scheduler, will require submit option -e
if(my $check = getProgramPath('qhost')){
    $qType = 'SGE';
    $schedulerDir = dirname($check);
    $submitTarget = "$schedulerDir/qsub";
} elsif($check = getProgramPath('showq')){
    $qType = 'PBS';
    $schedulerDir = dirname($check);
    $submitTarget = "$schedulerDir/qsub";
} elsif($check = getProgramPath('sbatch')){
    $qType = 'slurm';
    $schedulerDir = dirname($check);
    $submitTarget = "$schedulerDir/sbatch";
}
#------------------------------------------------------------------------
# parse the path to the job manager program and environment targets
#------------------------------------------------------------------------
$script = "$jobManagerDir/jobManager";
my $libDir = "$jobManagerDir/lib";
#------------------------------------------------------------------------
# print the job manager program target script
#------------------------------------------------------------------------
open my $outH, ">", $script or die "could not open $script for writing: $!\n";
print $outH
'#!'.$perlPath.'
use strict;
use warnings;

# DO NOT EDIT THIS FILE
# it is created automatically by \'initialize.pl\'

# set names and paths
our $rootDir  = '."'$ENV{ROOT_DIR}'".';
our $jobManagerDir  = '."'$jobManagerDir'".';
our $jobManagerName = '."'$jobManagerName'".';
our $perlPath = '."'$perlPath'".';
our $bashPath = '."'$bashPath'".';
our $libDir = '."'$libDir'".';
our $qType = '."'$qType'".';
our $schedulerDir = '."'$schedulerDir'".';
our $submitTarget = '."'$submitTarget'".';

# provide /usr/bin/time configuration information
our $timePath = '."'$timePath'".';
our $timeVersion = '."'$timeVersion'".';
our $memoryCorrection = '."'$memoryCorrection'".';
our $memoryMessage = '."'$memoryMessage'".';

# set environment variables passed to jobs
$ENV{Q_TYPE} = '."'$qType'".';

# set autoflush for interactive feedback
$| = 1;

# start the job manager application
require "$jobManagerDir/lib/main/main.pl";
jobManagerMain();
';
close $outH;

#------------------------------------------------------------------------
# make the job manager program target script executable
#------------------------------------------------------------------------
qx|chmod ugo+x $script|;

#------------------------------------------------------------------------
# add the mdi target program to the user's PATH
# TODO: implement auto-completion script and activate in .bashrc
#------------------------------------------------------------------------
sub slurpFile {  # read the entire contents of a disk file into memory
    my ($file) = @_;
    local $/ = undef; 
    open my $inH, "<", $file or die "could not open $file for reading: $!\n";
    my $contents = <$inH>; 
    close $inH;
    return $contents;
}
my $bashRc = "$ENV{HOME}/.bashrc";
my $bashRcContents = slurpFile($bashRc);
my $bashRcBlock = "
# >>> mdi-pipelines initialize >>>
# !! Contents within this block are managed by '$jobManagerName initialize' !!
export PATH=\"$ENV{ROOT_DIR}:\$PATH\"
# <<< mdi-pipelines initialize <<<
";
$bashRcContents =~ m/$bashRcBlock/ and exit;
open $outH, ">>", $bashRc or die "could not append to:\n    $bashRc\n$!\n";
print $outH $bashRcBlock;
close $outH;
#========================================================================

