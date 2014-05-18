package Term::ReadLine::CLISH;

=encoding UTF-8
=head1 NAME

Term::ReadLine::CLISH — command line interface shell

=cut

=head1 SYNOPSIS

XXX: Cut from example/MyShell.pm

=cut

use Moose;
use namespace::autoclean;
use Term::ReadLine;
use Term::ReadLine::CLISH::Parser;
use common::sense;

our $VERSION = '0.0000'; # string for the CPAN

has qw(prompt is rw isa Str default) => "clish> ";
has qw(path   is rw isa pathArray coerce 1 default) => sub { [@INC] };
has qw(prefix is rw isa prefixArray coerce 1 default) => sub {['Term::ReadLine::CLISH::Library::Commands']};
has qw(name is ro isa Str default) => "CLISH";
has qw(version is ro isa Str default) => $VERSION;
has qw(history_location is rw);
has qw(term is rw isa Term::ReadLine);
has qw(parser is rw isa Term::ReadLine::CLISH::Parser);
has qw(done is rw isa Bool);
has qw(cleanup is rw isa ArrayRef[CodeRef] default) => sub { [sub { say "\r\e[2Kbye" }] };

sub DEMOLISH {
    my $this = shift;
    $_->($this) for @{ $this->cleanup };
}

sub run {
    my $this = shift;
    my $term = Term::ReadLine->new($this->name);
    my $prsr = Term::ReadLine::CLISH::Parser->new(path=>$this->path, prefix=>$this->prefix);

    $this->term( $term );
    $this->parser( $prsr );

    eval { $term->ornaments('', '', '', '') };
    $this->init_history;

    print "Welcome to " . $this->name . " v" . $this->version . ".\n\n";

    push @{ $this->cleanup }, sub { shift->save_history };

    INPUT: while(!$this->done) {
        my $prompt = $this->prompt;
        $_ = $term->readline($prompt);
        last INPUT unless defined;
        s/^\s*//; s/\s*$//; s/[\r\n]//g;

        my @P = $prsr->parse($_);
        if( @P == 1 ) {
            my ($obj, @args) = @{ $P[0] };

            $obj->exec( @args );

        } elsif( @P ) {
            my @names = map { $_[0]->name } @{ $P[0] };
            local $" = ", ";
            say "% Ambiguous command: @names"

        } else {
            say "% unknown command: \"$_\""
        }
    }
}

sub init_history {
    my $this = shift;
    my $term = $this->term;

    my $hl = $this->history_location;
    if( !$hl ) {
        my $n = lc $this->name;
        $this->history_location( $hl = "$ENV{HOME}/.$n\_history" );
    }
    $term->read_history($hl);
    print "[loaded ", int ($term->GetHistory), " command(s) from history file]\n";
}

sub save_history {
    my $this = shift;
    my $term = $this->term;
    my $hl = $this->history_location;

    return unless $hl;
    $term->write_history($hl);
    $term->history_truncate_file($hl, 100);
}

__PACKAGE__->meta->make_immutable;

1;
