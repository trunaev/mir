package Sub::Daemon;

=head1 NAME

Sub::Daemon - base class for a daemons

=cut

use 5.014;

our $VERSION = '0.04';

use base 'Class::Accessor';
__PACKAGE__->mk_ro_accessors( qw( pid log logdir piddir logfile pidfile debug loglevel) );

use AnyEvent;
use POSIX ":sys_wait_h";
use File::Pid;
use Sub::Daemon::Log;
use FindBin;
use Carp;


sub new {
    my $class = shift;
    my %opts  = (
    	'logdir'	=> './',
    	'piddir'	=> './',
        'logfile'	=> undef,
        'pidfile'	=> undef,
        'debug'		=> 0,
        'loglevel'	=> 'info',
        @_,
    );

    my $logfile = $opts{ 'logfile' };
    my $pidfile = $opts{ 'pidfile' };

    unless ($logfile && $pidfile) {
        my $filename = $0;
        $filename =~ s/^.*\///;
        $logfile ||= $filename . '.log';
        $pidfile ||= $filename . '.pid';
    }

    my $self = bless {
        %opts,
        'logfile' => $logfile,
        'pidfile' => $pidfile,
    }, $class;

    $self->pid_check();
    $self->init_log();

    return $self;
}

=head2 _fork

Fork with dances

Return:
  pid of child process - for parent
  0 - for a child process

=cut

sub _fork {
    my $self = shift;

    my $pid;
    my $loop = 0;

    FORK: {
        if( defined( $pid = fork ) ) {
            return $pid;
        }

        # EAGAIN - fork cannot allocate sufficient memory to copy the parent's
        #          page tables and allocate a task structure for the child.
        # ENOMEM - fork failed to allocate the necessary kernel structures
        #          because memory is tight.
        # Last the loop after 30 seconds
        if ( $loop < 6 && ( $! == POSIX::EAGAIN() ||  $! == POSIX::ENOMEM() ) ) {
            $loop++; sleep 5; redo FORK;
        }
    }

    confess "Can't fork: $!";
}

=head2 _daemonize

Daemonize of process.
Forks, closes STDIN/STDOUT/STDERR....

=cut

sub _daemonize {
    my $self = shift;
    my %opts = (
        'pid'   => undef,
        'debug' => undef,
        @_,
    );
    
    my $debug = $opts{'debug'} // $self->debug;

    return $self->pid_write() if $debug;
    if (my $pid = $self->pid_check()) {
        die "Already running: $pid\n" ;
    }

    # ????????????????????????????
    # ???????????? fork
    my $pid = $self->_fork(); 
    if( $pid ) {
        waitpid $pid, 0;
        exit;
    }

    die "Can't <chdir> to $FindBin::Bin/script: $!" unless chdir $FindBin::Bin;
    umask 0;
    die "Cannot detach from controlling terminal" if POSIX::setsid() < 0;
    # ???????????? fork
    $pid = $self->_fork;
    exit if $pid;

    say "Daemon started. PID=$$";

    # ?????????????????? ?????? ???????????????? ??????????
    my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX ) // 64;
    $openmax = 64 if $openmax < 0;
    POSIX::close $_ for( 0 .. $openmax );
    # ?????????????????????????? ?????????????????????? ????????????
    open \*STDIN,  "</dev/null";
    open \*STDOUT, ">/dev/null";
    open \*STDERR, ">/dev/null";
    $self->init_log(); # ?????????????????? ?????? ?????? ??????, ??.??. ???? ?????? ???????????? ?? "POSIX::close ... "
    $self->pid_write();
    return;
}

=head2 pid_write

Write pid-file

=cut

sub pid_write {
    my $self     = shift;

    my $pidfile = $self->piddir . $self->pidfile;
    my $pid = File::Pid->new({
        'file' => $pidfile,
        'pid'  => $$,
    });
    if( -f -s $pidfile ) {
        if ( my $num = $pid->running ) {
            die "Already running: $num\n";
        }
    }

    $self->{'pid'} = $pid;

    $pid->write or die "Couldnt write pid $pidfile";

    return;
}

=head2 pid_check

Checking, may by this daemon runned early

=cut

sub pid_check {
    my $self     = shift;

    my $pidfile = $self->piddir . $self->pidfile;
    my $pid = File::Pid->new({
        'file' => $pidfile,
        'pid'  => $$,
    });

    return $pid->running if -f -s $pidfile;
    return;
}

=head2 pid_remove

Remove pid-file

=cut

sub pid_remove {
    my $self = shift;
    return $self->pid->remove;
}

=head2 init_log

Init log.

=cut

sub init_log {
    my $self     = shift;
    #my $filename = $ENV{LOG_DIR} . '/' . $self->logfile unless $self->debug;
    #$self->{ 'log' } = Rept::Log->new( 'path' => $filename );
    if ($self->debug) {
    	$self->{log} = Sub::Daemon::Log->new(level => $self->loglevel());
    } else {
    	$self->{log} = Sub::Daemon::Log->new(level => $self->loglevel(),path => $self->logdir() . $self->logfile);
    }

    $SIG{ '__WARN__' } = sub { 
        my $msg = $_[0];
        chomp $msg;
        $self->log->warn($msg);
    };    

    return;
}

=head2 spawn( 

Start child worker proccess. Control of work

Params:

    nproc - Number of childs process. Be default: 1
    code  - CODE REF of child process

=cut

sub spawn {
    my $self = shift;
    my %opts = (
        'nproc' => 1,
        'code'  => undef,
        @_,
    );
    
    $self->log->info("Daemon spawning");

    my $nproc = $opts{ 'nproc' } or confess 'number of child process is not specified';
    my $code  = $opts{ 'code' } or confess 'child code is not specified';
    confess 'code must be CODE reference' unless ref $code eq 'CODE';

    # ?????? ?????????? ?????????????? ??????????????????
    my %childs = ();
    
    my %childs_nums = ();

    my $cv = AE::cv;

    # ???????????????? ???????????????? INT ?? TERM
    # ?????? ???? ?????????????????? ?????????? ???????????????????? ???????? ????????????????????, 
    # ?? ???????? ?????????????? ?????????????????? ?????????? ?????????????????? ???????????? TERM
    $SIG{$_} = sub { $cv->send(); kill 'TERM' => keys %childs } for qw( TERM INT );

    # ????????, ??????????????????????, ?????? ?????? ???????????????? ??????????????. ?????????????????????????? ?? ???????????????? ????????????????)
    # ????-???? ?????????????????????? AnyEvent, ???????????????????? ???????????? ?????????? $self->run_child() ?????????? ???? $start_child,
    # ?? ???????????????????? ???????????????? ?????? ???? $cv->recv.
    my $is_child = 0;

    # ???????????????????????? ?????????????? ????????????????-?????????????????? ????????????????
    state $start_child = sub {
		my $child_num = shift;
		my $pid = $self->_fork();
        if ($pid) {
            # ?? ???????????????????????? ????????????????: 
            # ???????????? ?????????????????? pid ???????????????? ????????????????, 
            # ?? ?????????????????? ???????????????????? ????????????????????????
            $childs{ $pid } = 1;
            $childs_nums{ $pid } = $child_num;
            return;
        } else {
			$childs_nums{ $$ } = $child_num;
		}
        # ?? ???????????????? ????????????????:
        $cv->send;          # ?????????????????? ???????????????????? ???????????????? AE
        $is_child = 1;      # ???????????? ????????, ?????? ???????????? ?????????????? - ????????????????
        $self->log->info("Child process $$ started");
        return 1;
    };

    # callback, ?????????????????????????? ?? ???????????????? ????????????????, 
    # ?????????? ?????????????????????? ???????????????? ?????????????? ????????????????
    my $c = AE::child 0 => sub {
		my $pid = shift;
        if (delete $childs{ $pid }) {
            $self->log->info("Child process $pid stopped");
            # ?????????????? pid,            
            # ???????? ?????? ???? ???????????? ???????????????????? ???????????? ?????????????? (???????? ?????????????????? AE ?????? ???? ????????????????????), 
            # ???????????? ?????????????? ???????????????? ???????? ??????, ?? ?????????? ?????? ??????????????????????????
            $start_child->($childs_nums{$pid}) unless $cv->ready;
            delete $childs_nums{$pid};
        }
    };

    # ???????????????????? ?????????????? HUP.
    my $hup = AE::signal HUP => sub {
        # ???????????????? HUP ???????? ???????????????? ??????????????????
        $self->log->info( 'Parent process fetch SIG HUP' );
        $self->log->info( 'Send HUP to child processes' );
        kill HUP => keys %childs;
        # ?????????????????????????? ????????
        #$self->log->info( 'Log reopening..' );
        #$self->log->reopen();
    };

    # ?????????????????? ???????????????? ????????????????
    # "&& last" ?????????? ????????, ?????????? ???????????????? ?????????????? ?????? ?????????? ???? ??????????.
    $start_child->($_) && last for 1..$nproc;

    # ???????????? ???????????????? ?????????????? AE
    $cv->recv;

    # ???????? ???????? ?????????????? - ????????????????, ???????????????? ??????????????????
    if ($is_child) {
        local $SIG{ 'HUP' } = sub {
            $self->log->info( 'Worker process fetch SIG HUP' );
            $self->log->info( 'Log reopening..' );
            $self->log->reopen();
        };
        $code->(child_num => $childs_nums{$$});
        exit;
    }

    # ???????????????????? ???????????????????? ???????????????????? ?????????????? ??????????????????
    $self->log->info("Waiting childs");
    waitpid($_, 0) for keys %childs;
    $self->log->info("Daemon finished");

    return;
}

sub stop {
	my $self = shift;
	
	$self->log->info("Stopping daemon");
	
	my $pidfile = $self->pidfile();
	open my $fi, $pidfile;
	my $pid = <$fi>;
	chomp $pid;
	close $fi;
	
	if (kill 0, $pid) {
		kill 'TERM', $pid;
	} else {
		die "Couldn't send kill 0 to master process";
	}
}

1;
