#!/usr/bin/perl -w
# $Id: sreq,v 1.7 2002/08/13 13:14:03 agriffis Exp $
#
# sreq: command-line srequest browser
#

BEGIN {
    $0 =~ /cgi$/ and do { 
        print "Content-Type: text/plain\n\n";
        use CGI qw/:standard/;
        @ARGV = split ' ', param('argv') if param('argv')
    }
}

use POSIX;
use Getopt::Long;
use strict;

######################################################################
# Global vars
######################################################################

(my $version = '$Revision: 1.7 $') =~ s/.*?(\d.*\d).*/sreq version $1\n/;
my $verbose = 0;
my %opt = (
    'v' => \$verbose,
);
my $usage = <<EOT;
usage: sreq [ -blqahv ] [-Q num] pool-nnn-user...

Output formats:

           --full          Output full text (default)
    -f     --files         Output file list
    -l     --list          Output simple list
    -q     --qars          Output QAR list
    -a     --abstract      Output abstract list
    -s     --submits       Output submit history

Output modifiers:

    -b           --siblings  Include siblings in the output
    -Q num       --qar       Find srequest addressing QAR num
    -F filename  --file      Find srequest modifying file

Other information:

    -h     --help          Show this help message
    -v     --verbose       Verbose output
    -V     --version       Show version information
EOT

######################################################################
# Utility routines
######################################################################

package Utility;

# getcols: returns the number of columns on the terminal (Linux or Tru64)
sub getcols {
    my ($row, $col, $xpixel, $ypixel, $winsize, $TIOCGWINSZ);
    if ((POSIX::uname)[0] eq 'OSF1') {
        # Tru64 UNIX
        print STDERR "Detected Tru64 UNIX\n" if $verbose > 1;
        $TIOCGWINSZ = 0x40000000 | ((8 & 0x1fff) << 16) | (116 << 8) | 104;
    } else {
        # Linux
        print STDERR "Detected Linux\n" if $verbose > 1;
        require "asm/ioctls.ph";
        $TIOCGWINSZ = &TIOCGWINSZ;
    }
    open(TTY, "+</dev/tty") or return 132;
    local $^W = 0; # seems $winsize needs to be undef
    ioctl(TTY, $TIOCGWINSZ, $winsize) or return 132;
    print STDERR "ioctl TIOCGWINSZ returned $winsize\n" if $verbose > 1;
    # or die "ioctl TIOCGWINSZ: $!";
    ($row, $col, $xpixel, $ypixel) = unpack("S4", $winsize);
    print STDERR "getcols = $col\n" if $verbose;
    return $col;
}

######################################################################
# Srequest class
######################################################################

package Srequest;

sub new {
    my ($class, $fn) = @_;
    die "new Srequest requires filename or id" unless $fn;
    if ($fn !~ m#/#) {
        # transform an id into a filename
        (my $p = $fn) =~ s/-.*//;
        my (@fn) = glob "/usr/sde/osf1/build/$p/logs/srequest/*/$fn";
        unless (@fn) {
            print STDERR "Warning: can't find $fn\n";
            return undef;
        }
        $fn = $fn[0];   # why would there be more?
    }
    (my $id = $fn) =~ s/.*\///;
    (my $pool = $id) =~ s/-.*//;
    (my $num  = $id) =~ s/.*-(.*)-.*/$1/;
    (my $user = $id) =~ s/.*-//;
    my $self = {
        id       => $id,
        pool     => $pool,
        num      => $num,
        user     => $user,
        filename => $fn,
        abstract => undef,
        qars     => undef,
        files    => undef,
        siblings => undef,
    };
    bless $self, $class;
    return $self;
}

sub readTop {
    my ($self) = @_;
    if (!open F, $self->{filename}) {
        warn "sreq: can't read $self->{filename}";
        return undef
    }

    # Use sysread since everything that interests us is bound to
    # be in the first 10k (we assume)
    my ($text);
    my ($bytes) = sysread F, $text, 10*1024;
    printf STDERR "readTop read %d bytes\n", $bytes if $verbose;

    # Remove changebars
    $text =~ s/^\| //gm;

    # Extract the QAR numbers
    @{$self->{qars}} = ($text =~ /^\d{5,6}(?=\s)/gm);
    printf STDERR "Extracted QARs @{$self->{qars}}\n" if $verbose;

    # Extract the abstract
    if ($text =~ /^(?:o Submit Abst|1a\) Patch Announ).*\n[\s\|]*(\S.*)\n/m) {
        ($self->{abstract} = $1) =~ s/\t/ /g; # convert tabs -> spaces
    } else {
        $self->{abstract} = '';
    }
    printf STDERR "Extracted Abstract $self->{abstract}\n" if $verbose;

    # Leave F open since it might be used next by readAll... gross I know
    return $text;
}

sub readAll {
    my ($self) = @_;
    my ($text) = $self->readTop;   # who cares if this is the second time
    my ($new_text);

    # Use the filehandle left open by readTop.  It's safe in this
    # situation to mix sysread and buffered reads because of the
    # ordering...
    { 
        local $/ = undef;
        $new_text = <F>;          # snarf to EOF
    }
    printf STDERR "readAll read %d bytes\n", length($new_text) if $verbose;

    if (defined($new_text)) {
        if ($text !~ /\n$/) {     # Fix up last/first lines
            $new_text =~ s/^.*?\n//;
            $text .= $&;
            printf STDERR "readAll fixed up: %s", $& if $verbose > 1;
        }
        $new_text =~ s/^\| //gm;  # Remove changebars from the new text
        $text .= $new_text;       # Tack it together
    }

    # Extract the changed files
    my (%files) = ();
    while ($text =~ /^\[\s+(\S*\/\S*)\s+\]/gm) { $files{$1} = 1; }
    @{$self->{files}} = sort keys %files;

    print STDERR "Extracted Files\n", map "\t$_\n", @{$self->{files}} 
        if $verbose;

    # Extract the siblings
    my (@siblings) = ();
    while ($text =~ /.*?\n/g) {
        $_ = $&; # strange but true
        next unless /Sibling Srequest/..0;
        /=Section 3. Testing=/ and last;
        /\b[^-\s]+-\d+-[^-\s]+\b/ && push @siblings, $&;
    }
    @{$self->{siblings}} = @siblings;

    print STDERR "Extracted Siblings\n", map "\t$_\n", @{$self->{siblings}}
        if $verbose;
}

sub id {
    my ($self) = @_;
    return $self->{id};
}

sub pool {
    my ($self) = @_;
    return $self->{pool};
}

sub num {
    my ($self) = @_;
    return $self->{num};
}

sub user {
    my ($self) = @_;
    return $self->{user};
}

sub filename {
    my ($self) = @_;
    return $self->{filename};
}

sub qars {
    my ($self) = @_;
    $self->readTop unless defined $self->{qars};
    return @{$self->{qars}};
}

sub files {
    my ($self) = @_;
    $self->readAll unless defined $self->{files};
    return @{$self->{files}};
}

sub siblings {
    my ($self) = @_;
    $self->readAll unless defined $self->{siblings};
    return @{$self->{siblings}};
}

sub abstract {
    my ($self) = @_;
    $self->readTop unless defined $self->{abstract};
    return $self->{abstract};
}

######################################################################
# Sreqlist class
######################################################################

package Sreqlist;

use constant NO_TRUNCATE  => 0;
use constant YES_TRUNCATE => 1;

sub new {
    my ($class, @patt) = @_;
    die "new Sreqlist requires pattern" unless @patt;

    # Init
    my $self = {
        sreqs => [],   # Srequest instances
    };
    bless $self, $class;

    # Build list of matching srequests
    for my $p (@patt) {

        # Parse srequest_id from command-line
        my ($id, $pool, $num, $user, @dirs, @files);
        $p =~ /^\s*(\S*)-(\S*)-(\S*)\s*$/
            or die "sreq: can't parse srequest_id from $p\n$usage";
        $pool = length($1) ? $1 : '*';
        $num  = length($2) ? $2 : '*';
        $user = length($3) ? $3 : '*';
        $id   = "$pool-$num-$user";
        print STDERR "Pool=[$pool] Num=[$num] User=[$user]\n" if $verbose;

        # Pare down $pool so that only submit pools are checked.  The
        # assumption is that submit pools don't contain a dot in the directory
        # name (.); this may not always be true.
        @dirs = grep { -d $_ && /^[\/\w]+$/ } glob "/usr/sde/osf1/build/$pool";
        die "sreq: no matching pool for $pool\n" unless @dirs;
        printf STDERR "Matching submit pools are:\n\t%s\n", join "\n\t", @dirs
            if $verbose;

        # Find all the matching files; using glob() seems faster than find.
        @files = ();
        for my $d (@dirs) {
            #push @files, grep { -f $_ } glob "$d/logs/srequest/*/$id"; 
            push @files, glob "$d/logs/srequest/*/$id"; 
        }
        die "sreq: $id not found\n" unless @files;
        printf STDERR "Matching files are:\n\t%s\n", join "\n\t", @files
            if $verbose;

        # Create a new Srequest instance for each one
        for my $f (@files) {
            push @{$self->{sreqs}}, new Srequest($f);
        }
    }

    # Sort the sreqs in place
    @{$self->{sreqs}} = sort {
        my $na = (split '-', $a->id, 3)[1];
        my $nb = (split '-', $b->id, 3)[1];
        $na <=> $nb;
    } @{$self->{sreqs}};

    # return me
    return $self;
}

sub addSiblings {
    my ($self) = @_;
    my (@new_sreqs) = @{$self->{sreqs}};
    my (%newlist) = ();   # keyed by srequest ids

    # Mark these as completed
    for my $s (@{$self->{sreqs}}) { $newlist{$s->id} = 1; }

    # Now add the siblings
    for my $s (@{$self->{sreqs}}) {
        for my $sib ($s->siblings) {  # note these are ids
            unless (defined($newlist{$sib})) {
                # SreqList requires Sreq objects
                my ($new_sreq) = new Srequest($sib);
                push @new_sreqs, $new_sreq if defined $new_sreq;
                $newlist{$sib} = 1;  # even if it didn't work!
            }
        }
    }
    # Could go recursive here, but nah...

    @{$self->{sreqs}} = @new_sreqs;
}

sub filterQAR {
    my ($self, $thisqar) = @_;
    my (@newlist);
    print STDERR "filterQAR searching for $thisqar\n" if $verbose;
    for my $s (@{$self->{sreqs}}) {
        if (grep $_ eq $thisqar, $s->qars) { 
            push @newlist, $s; 
            print STDERR "\tkeeping ", join(" ", $s->id, $s->qars), "\n" 
                if $verbose;
        }
        else {
            print STDERR "\tremoving ", join(" ", $s->id, $s->qars), "\n" 
                if $verbose;
        }
    }
    $self->{sreqs} = \@newlist;  # doh! forgot this for a while...
}

sub filterFile {
    my ($self, $thisfile) = @_;
    my (@newlist);
    print STDERR "filterFile searching for $thisfile\n" if $verbose;
    for my $s (@{$self->{sreqs}}) {
        if (grep $_ =~ m#/$thisfile$#, $s->files) { 
            push @newlist, $s; 
            print STDERR "\tkeeping ", join(" ", $s->id, $s->files), "\n" 
                if $verbose;
        }
        else {
            print STDERR "\tremoving ", join(" ", $s->id, $s->files), "\n" 
                if $verbose;
        }
    }
    $self->{sreqs} = \@newlist;  # doh! forgot this for a while...
}

sub outputLines {
    my ($shouldTrunc) = shift @_;
    my (@lines) = @_;
    if ($shouldTrunc == YES_TRUNCATE) {
        my ($cols) = Utility::getcols() - 1;
        for my $s (@lines) { printf "%-${cols}.${cols}s\n", $s; }
    } else {
        for my $s (@lines) { print "$s\n"; }
    }
}

sub outputQAR {
    my ($self) = @_;
    outputLines NO_TRUNCATE,
        map $_->id.": ".join(" ", $_->qars), @{$self->{sreqs}};
}

sub outputAbstract {
    my ($self) = @_;
    outputLines YES_TRUNCATE, map $_->id.": ".$_->abstract, @{$self->{sreqs}};
}

sub outputList {
    my ($self) = @_;
    outputLines NO_TRUNCATE, map $_->id, @{$self->{sreqs}};
}

sub outputFiles {
    my ($self) = @_;
    for my $s (@{$self->{sreqs}}) {
        print $s->id, ":\n";
        print "\t", join("\n\t", $s->files), "\n\n";
    }
}

sub outputSubmits {
    my ($self) = @_;

    # One pass per srequest.  NFS caching should mostly alleviate
    # this, and it's more likely to be run for one srequest.
    for my $s (@{$self->{sreqs}}) {
        print "=" x length($s->id), "\n";
        print $s->id, "\n"; 
        print "=" x length($s->id), "\n\n";
        my $cmd = "/usr/bin/grep -p " . $s->id . 
                  " /usr/sde/osf1/build/" . $s->pool .
                  "/logs/monitor_submit.log";
        unless (open F, "$cmd|") {
            warn "sreq: couldn't run grep";
            return undef;
        }
        print <F>;
        close F;
    }
}

sub outputFull {
    my ($self) = @_;
    my (@files) = map $_->filename, @{$self->{sreqs}};
    if (POSIX::isatty(\*STDOUT)) {
        my $pager = $ENV{'PAGER'} || 'more';
        print STDERR "Running xargs $pager with stdin of @files\n" if $verbose;
        # use xargs to keep cmdline arguments sane
        open F, "|xargs $pager";
        print F "@files\n";
        close F;
    } elsif (@files > 1) {
        for my $f (@files) {
            (my $id = $f) =~ s/.*\///;  # duplicated but easier
            open F, $f or next;
            print "::::::::::::::\n$id\n::::::::::::::\n", <F>;
        }
    } else {
        open F, $files[0];
        print <F>;
    }
}

######################################################################
# Main
######################################################################

package main;

# Allow bundling of options
Getopt::Long::Configure("bundling");

# Parse the options on the cmdline.  Put the short versions first in
# each optionstring so that the hash keys are created using the short
# versions.  For example, use 'q|qar', not 'qar|q'.
my ($result) = GetOptions(
    \%opt,
    'a|abstract',       # output abstracts
    'b|siblings',       # include siblings in output
    'full',             # output full text (default)
    'f|files',          # output file list
    'F|file=s',         # select by file modified
    'h|help',           # help message
    'l|list',           # output simple list
    'Q|qar=s',          # select by qar number
    'q|qars',           # output qars
    's|submits',        # output submit history
    'v|verbose+',       # verbose, more v's for more verbosity
    'V|version',        # version information
);
if ($opt{'h'}) { print STDERR $usage; exit 0 }
if ($opt{'V'}) { print STDERR $version; exit 0 }
die "sreq: argument required\n$usage" unless @ARGV;

# Build a list of srequests matching the input pattern(s)
my ($slist) = new Sreqlist(@ARGV);
if (@{$slist->{sreqs}} == 0) {
    print STDERR "sreq: no matching srequests found\n";
    exit 1;
}

# Filter the list
$slist->filterQAR($opt{'Q'}) if defined $opt{'Q'};
$slist->filterFile($opt{'F'}) if defined $opt{'F'};
$slist->addSiblings() if defined $opt{'b'};

# Output in requested format
{
    defined $opt{'f'} and $slist->outputFiles,    last;
    defined $opt{'q'} and $slist->outputQAR,      last;
    defined $opt{'a'} and $slist->outputAbstract, last;
    defined $opt{'s'} and $slist->outputSubmits,  last;
    defined $opt{'l'} and $slist->outputList,     last;
    $slist->outputFull;
}

__END__

=head1 NAME

sreq - command-line srequest browser

=head1 SYNOPSIS

B<sreq> [I<-bflqahvV>] 
[I<--list --files --qars --abstract --siblings --submits 
    --help --verbose --version>] 
[I<-Q num | --qar num>] [I<--F filename | --file <filename>] pool-nnn-user...

=head1 OPTIONS

=over

=item B<--full>

Output full srequest text.  This is the default.

=item B<-a --abstract>

Output in abstract list format, one srequest per line with abstracts.

=item B<-b --siblings>

Include siblings in the output.

=item B<-f --files>

Output files modified by the srequests.  Note that this is only as
accurate as the srequest text.

=item B<-l --list>

Output in simple list format, one srequest per line.

=item B<-q --qars>

Output in QAR list format, one srequest per line with QAR numbers.

=item B<-s --submits>

Output in submit history format.

=item B<-F> I<filename> B<--file> I<filename>

Filter srequests on file modified by the srequest.  pool-nnn-user is
still required to determine where to look.

=item B<-Q> I<num> B<--qar> I<num>

Filter srequests on QAR number.  pool-nnn-user is still required to
determine where to look.

=item B<-h --help>

Show help information.

=item B<-v --verbose>

Run in verbose mode (for debugging).

=item B<-V --version>

Show version information.

=back

=head1 DESCRIPTION

This tool provides a command-line interface for looking up srequests.

=head1 EXAMPLES

To view a given srequest:

    $ sreq wcalphaos-633-agriffis
    [pager starts with srequest]

To see a list of your srequests to wcalpha, use something like the following:

    $ sreq --abstract wcalphaos-*-agriffis
    wcalphaos-633-agriffis: alt driver: MAC address fixes, vMAC promisc
    wcalphaos-859-agriffis: Merge of V51ASUPPORT BL2 into WCALPHA BL3

To show the QARs addressed by those srequests, do:

    $ sreq --qars wcalphaos-*-agriffis
    wcalphaos-633-agriffis: 89295 89838 82052 89637
    wcalphaos-859-agriffis: 

To search by QAR number and output in simple list format:

    $ sreq --list --qar=89637
    wcalphaos-633-agriffis

To show the siblings for a given srequest:

    $ sreq --list --siblings v51asupportos-272-amg
    v40fsupportos-855-amg
    v51asupportos-646-amg
    v51supportos-816-amg
    v50asupportos-671-amg
    v40gsupportos-485-amg

To search by file modified and output the abstracts:

    $ sreq --abstract --file=bcm.c indepos-*-agriffis
    indepos-24-agriffis: Initial submit of bcm driver V1.0.1 to indepos
    indepos-25-agriffis: Submit bcm driver V1.0.2 with additional 0x1646 PCI
    indepos-32-agriffis: bcm V1.0.4 with 5704 support

=head1 ENVIRONMENT VARIABLES

=over

=item PAGER

The PAGER variable is honored when viewing srequest texts.

=back

__END__

$Log: sreq,v $
Revision 1.7  2002/08/13 13:14:03  agriffis
fixed synopsis in man-page

Revision 1.6  2002/08/13 10:58:21  agriffis
fixed usage

Revision 1.5  2002/08/13 10:52:32  agriffis
added --siblings, --files, and --file

Revision 1.4  2002/08/06 21:25:21  agriffis
added ability to act as a cgi when named *.cgi

Revision 1.3  2002/06/27 12:50:47  agriffis
added --version and fixed up the man-page

Revision 1.2  2002/06/27 02:55:10  agriffis
complete rewrite.  now object-oriented and with submit history.

Revision 1.1.1.1  2002/04/16 13:47:57  agriffis
sreq command-line srequest tool
