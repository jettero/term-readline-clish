
package Term::ReadLine::CLISH::Parser;

use Moose;
use namespace::autoclean;
use Moose::Util::TypeConstraints;
use Term::ReadLine::CLISH::MessageSystem;
use Parse::RecDescent;
use File::Find::Object;
use common::sense;
use constant {
    PARSE_COMPLETE => 1,

    PARSE_RETURN_TOKENS  => 0,
    PARSE_RETURN_CMDS    => 1,
    PARSE_RETURN_ARGSS   => 2,
    PARSE_RETURN_STATUSS => 3,
};

subtype 'pathArray', as 'ArrayRef[Str]';
coerce 'pathArray', from 'Str', via { [ split m/[:; ]+/ ] };

subtype 'prefixArray', as 'ArrayRef[Str]';
coerce 'prefixArray', from 'Str', via { [ $_ ] };

subtype 'cmd', as 'Term::ReadLine::CLISH::Command';
subtype 'cmdArray', as 'ArrayRef[cmd]';
coerce 'cmdArray', from 'cmd', via { [ $_ ] };

has qw(path is rw isa pathArray coerce 1);
has qw(prefix is rw isa prefixArray);
has qw(cmds is rw isa cmdArray coerce 1);
has qw(tokenizer is rw isa Parse::RecDescent);

has qw(output_prefix is rw isa Str default) => "% ";

__PACKAGE__->meta->make_immutable;

sub parse_for_execution {
    my $this = shift;
    my $line = shift;
    my ($tokens, $cmds, $argss, $statuss) = $this->parse($line);

    if( not $tokens ) {
        error "tokenizing input"; # the tokenizer will have left an argument in $@
        return;
    }

    return unless @$tokens;

    if( @$cmds == 1 ) {
        if( $statuss->[0] == PARSE_COMPLETE ) {
            debug "selected $cmds->[0] for execution" if $ENV{CLISH_DEBUG};
            return ($cmds->[0], $argss->[0]);

        } elsif ($statuss->[0]) {
            error "parsing $cmds->[0] arguments", $statuss->[0];
            return;
        }
    }

    elsif( @$cmds ) {
        error "\"$tokens->[0]\" could be any of these", join(", ", map { $_->name } @$cmds);

    } else {
        error "parsing input", "unknown command '$tokens->[0]'";
    }

    return;
}

=head1 C<parse()>

    my ($tokens, $cmds, $args_star, $statuses) = $this->parse($line);

The C<parse> method returns an arrayref of tokens from the line in C<$tokens>,
an arrayref of possible commands in C<$cmds>, an arrayref of hashrefs (each
hashref the parsed arguments for the commands as C<< tag=>value >> pairs), and
an arrayref of C<$statuses>.

The statuses are either the value C<PARSE_COMPLETE> or a string representing any
errors with intepreting the line as an invocation of the command at the same
index.

Example:

    if( @$cmds == 1 and $statuses->[0] == PARSE_COMPLETE ) {
        info "executing $cmds->[0]";
        $cmds->[0]->exec( $args_star->[0] );
    }

Exception: if the tokenizer (an actual parser) can't make sense of the line,
C<parse> will return an empty list and leave the parse error in C<$@>.

=cut

sub parse {
    my $this = shift;
    my $line = shift;
    my %options;

    my @return = ([], [], [], []);

    if( $line =~ m/\S/ ) {
        my $prefix    = $this->output_prefix;
        my $tokenizer = $this->tokenizer;
        my $tokens    = $tokenizer->tokens( $line );

        return unless $tokens; # careful to not disrupt $@ on the way up XXX document this type of error (including $@)

        debug do { local $" = "> <"; "tokens: <@$tokens>" } if $ENV{CLISH_DEBUG};

        if( @$tokens ) {
            my ($cmd_token, @arg_tokens) = @$tokens;

            $return[0] = $tokens;
            my @cmds = grep {substr($_->name, 0, length $cmd_token) eq $cmd_token} @{ $this->cmds };

            $return[ PARSE_RETURN_CMDS ] = \@cmds;

            for my $cidx ( 0 .. $#cmds ) {
                my $cmd = $cmds[$cidx];
                my @cmd_args = @{ $cmd->arguments };

                debug "cmd_args: @cmd_args" if $ENV{CLISH_DEBUG};

                $return[ PARSE_RETURN_ARGSS ][ $cidx ] = my $out_args = +{ map {($_->name,$_)} @cmd_args };

                # NOTE: it's really not clear what the best *generalized* arg
                # processing strategy is best.  For now, I'm just doing it
                # really dim wittedly.

                $this->_try_to_eat_tok( $cmd,$out_args => \@cmd_args,\@arg_tokens );

                # if there are remaining arguments, reject the command
                if( my @extra = map {"\"$_\""} @arg_tokens ) {
                    local $" = ", ";
                    $return[ PARSE_RETURN_STATUSS ][ $cidx ] = "extra tokens on line (@extra)";
                    next;
                }

                # if some of the arguments are missing, reject the command
                if( my @req = grep { $_->required } @cmd_args ) {
                    local $" = ", ";
                    $return[ PARSE_RETURN_STATUSS ][ $cidx ] = "required arguments omitted (@req)";
                    next;
                }

                $return[ PARSE_RETURN_STATUSS ][ $cidx ] = PARSE_COMPLETE;
            }
        }
    }

    return @return;
}


sub _try_to_eat_tok {
    my $this = shift;
    my ( $cmd,$out_args => $cmd_args,$arg_tokens ) = @_;

    # $cmd is the command object
    # $out_args is the hashref of return arguments
    # $cmd_args are the command args not yet consumed by the parse
    # $arg_tokens are the tokens representing args not yet consumed by the parse

    for my $tidx ( 0 .. $#$arg_tokens ) {
        $this->_try_to_eat_tagged_arguments(   $tidx, @_ ) and redo;
        $this->_try_to_eat_untagged_arguments( $tidx, @_ ) and redo;
    }
}

sub _try_to_eat_tagged_arguments {
    my $this = shift;
    my ( $tidx, $cmd,$out_args => $cmd_args,$arg_tokens ) = @_;

    if( $tidx < $#$arg_tokens ) {
        my $tok  = $arg_tokens->[0];
        my $ntok = $arg_tokens->[$tidx+1];

        my @lv; # validated values for the array matching arrays
        my @ev; # errors from the validation

        my @matched_cmd_args_idx = # the indexes of matching Args
            grep { undef $@; my $v = $cmd_args->[$_]->validate($ntok);
                   $ev[$_] = $@; $lv[$_] = $v if $v; $v }
            grep { substr($cmd_args->[$_]->name, 0, length $tok) eq $tok }
            0 .. $#$cmd_args;

        if( @matched_cmd_args_idx == 1 ) {
            my $midx = $matched_cmd_args_idx[0];

            # consume the items
            my ($arg) = splice @$cmd_args, $midx, 1;
            my @nom   = splice @$arg_tokens, 0, 2;

            { local $" = "> <"; debug "ate $arg with <@nom>" if $ENV{CLISH_DEBUG}; }

            # populate the option in argss
            $arg->add_copy_with_value_to_hashref( $out_args => $lv[$midx] );

            return 1; # returning true reboots the _try*
        }

        elsif( my @dev = grep {defined $ev[$_]} 0 .. $#ev ) {
            warning "trying to use '$tok' => '$ntok' to fill $cmd\'s $cmd_args->[$_]",
                $ev[$_] for @dev;
        }

        else {
            # XXX: it's not clear what to do here
            # should we explain for every (un)matching
            # command?

            if( @matched_cmd_args_idx) {
                my @matched = map { $cmd_args->[$_] } @matched_cmd_args_idx;
                debug "$tok failed to resolve to a single validated tagged option,"
                    . " but initially matched: @matched" if $ENV{CLISH_DEBUG};
            }

            # I think we don't want to show anything in this case
            # else { debug "$tok failed to resolve to anything" }
        }
    }

    return;
}

sub _try_to_eat_untagged_arguments {
    my $this = shift;
    my ( $tidx, $cmd,$out_args => $cmd_args,$arg_tokens ) = @_;
    my $tok = $arg_tokens->[0];

    my @lv; # validated values for the array matching arrays
    my @ev; # errors from the validation

    my @matched_cmd_args_idx = # the idexes of matching Args
        grep { undef $@; my $v = $cmd_args->[$_]->validate($tok);
               $ev[$_] = $@; $lv[$_] = $v if defined $v; defined $v }
        grep { $cmd_args->[$_]->tag_optional }
        0 .. $#$cmd_args;

    if( @matched_cmd_args_idx == 1 ) {
        my $midx = $matched_cmd_args_idx[0];

        # consume the items
        my ($arg) = splice @$cmd_args, $midx, 1;
        my ($nom) = splice @$arg_tokens, 0, 1;

        { local $" = "> <"; debug "ate $arg with <$nom>" if $ENV{CLISH_DEBUG}; }

        # populate the option in argss
        $arg->add_copy_with_value_to_hashref( $out_args => $lv[$midx] );

        return 1; # returning true reboots the _try*
    }

    elsif( my @dev = grep {defined $ev[$_]} 0 .. $#ev ) {
        warning "trying to use '$tok' to fill $cmd\'s $cmd_args->[$_]",
            $ev[$_] for @dev;
    }

    else {
        # XXX: it's not clear what to do here should we
        # explain for every (un)matching command?

        if( @matched_cmd_args_idx ) {
            my @matched = map { $cmd_args->[$_] } @matched_cmd_args_idx;
            debug "$tok failed to resolve to a single validated tagged option,"
                . " but initially matched: @matched" if $ENV{CLISH_DEBUG};
        }

        # I think we don't want to show anything in this case
        # else { debug "$tok failed to resolve to anything" }
    }

    return;
}

sub BUILD {
    my $this = shift;
       $this->reload_commands;
       $this->build_parser;
}

sub build_parser {
    my $this = shift;

    my $prd = Parse::RecDescent->new(q
        tokens: token(s?) { $return = $item[1] } end_of_line
        end_of_line: /$/ | /\s*/ <reject: $text ? $@ = "unrecognized token: $text" : undef>
        token: word | string
        word: /[\w\d_.-]+/ { $return = $item[1] }
        string: "'" /[^']*/ "'" { $return = $item[2] }
              | '"' /[^"]*/ '"' { $return = $item[2] }
    );

    $this->tokenizer($prd);
}

sub command_names {
    my $this = shift;
    my @cmd  = @{ $this->cmds };

    my %h;
    return sort map { $_->name } grep { !$h{$_}++ } @cmd;
}

sub prefix_regex {
    my $this = shift;
    my @prefixes = @{ $this->prefix };
    s{::}{/}g for @prefixes;
    local $" = "|";
    my $RE = qr{(?:@prefixes)};
    return $RE;
}

sub reload_commands {
    my $this = shift;
    my $PATH = $this->path;
    my $prreg = $this->prefix_regex;

    my @cmds;

    for my $path (@$PATH) {
        my $ffo = File::Find::Object->new({}, $path);

        debug "trying to load commands from $path using $prreg" if $ENV{CLISH_DEBUG};

        while( my $f = $ffo->next ) {
            debug "    considering $f" if $ENV{CLISH_DEBUG};

            if( -f $f and my ($ppackage) = $f =~ m{($prreg.*?)\.pm} ) {
                my $package = $ppackage; $package =~ s{/}{::}g;
                my $newcall = "use $package; $package" . "->new";
                my $obj     = eval $newcall;

                if( $obj ) {
                    if( $obj->isa("Term::ReadLine::CLISH::Command") ) {
                        debug "    loaded $ppackage as $package" if $ENV{CLISH_DEBUG};
                        push @cmds, $obj;

                    } else {
                        debug "    loaded $ppackage as $package — but it didn't appear to be a Term::ReadLine::CLISH::Command" if $ENV{CLISH_DEBUG};
                    }

                } else {
                    error "trying to load '$ppackage' as '$package'";
                }
            }
        }
    }

    my $c = @cmds;
    my $p = $c == 1 ? "" : "s";

    info "[loaded $c command$p from PATH]";

    $this->cmds(\@cmds);
}

1;
