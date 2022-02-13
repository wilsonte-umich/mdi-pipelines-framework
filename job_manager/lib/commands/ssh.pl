use strict;
use warnings;

#========================================================================
# 'ssh.pl' executes an ssh command on the host/node running a live job
# if no command is provided, a shell is opened
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options %allJobs %targetJobIDs $taskID $pipelineOptions);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub qSsh { 

    # read required information from job log file
    my $mdiCommand = "ssh";
    my $logFileYamls = getJobLogFileContents($mdiCommand, 1);
    my %jmData;
    foreach my $yaml(@$logFileYamls){
        my $jm = $$yaml{'job-manager'} or next;
        foreach my $key(keys %$jm){
            $jmData{$key} = $$jm{$key}[0]
        }
    }
    $jmData{exit_status} and throwError("job has already finished or failed", $mdiCommand); 

    # pass the call to system ssh
    my $host = $jmData{host};
    $host or throwError("error processing job log file: missing host", $mdiCommand);     
    exec join(" ", "ssh -t $host", $pipelineOptions); # use -t (terminal) to support interactive commands like [h]top
}
#========================================================================

#========================================================================
# get the contents of the log file for a specific job, from option --job
#------------------------------------------------------------------------
sub getJobLogFileContents {
    my ($mdiCommand, $runningOnly) = @_;
    my $running = $runningOnly ? "running " : "";

    # initialize
    my $error = "command '$mdiCommand' requires a single $running"."job or task ID";
    my $tooManyJobs = "too many matching job targets\n$error";    
    $options{'no-chain'} = 1; 

    # get a single target job, or a single task of an array job
    getJobStatusInfo(); 
    parseJobOption(\%allJobs, $mdiCommand); 
    my @jobIDs = keys %targetJobIDs; 
    @jobIDs == 1 or throwError($tooManyJobs, $mdiCommand); 
    my $jobID = $jobIDs[0];

    # get and check the job/task log file
    my ($qType, $array, $inScript, $command, $instrsFile, $scriptFile, $jobName) = @{$targetJobIDs{$jobID}};
    my $logFiles;
    if(defined $taskID){
        $logFiles = [ getArrayTaskLogFile($qType, $jobID, $taskID, $jobName) ];
    } else {
        $logFiles = getLogFiles($qType, $jobName, $jobID, $array);
    }
    @$logFiles == 1 or throwError($tooManyJobs, $mdiCommand); 
    my $logFile = @$logFiles[0];  
    -e $logFile or throwError("job log file not found\n$error", $mdiCommand); 

    # extract the job manager status reports from the job/task log file
    my $yamls = loadYamlFromString( slurpFile($logFile) );
    $$yamls{parsed}; # a reference to an array of YAML chunks in the job's log file
}
#========================================================================

1;