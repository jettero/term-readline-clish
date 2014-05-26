
package Term::ReadLine::CLISH::Command::Argument;

use Moose;
use Memoize;
use namespace::sweep; # like autoclean, but doesn't murder overloads
use Moose::Util::TypeConstraints;
use Term::ReadLine::CLISH::MessageSystem;
use common::sense;
use overload '""' => \&stringify, fallback => 1;

subtype 'FunctionName', as 'Str', where { m/^(?:::|[\w\d_]+)*\z/ };
subtype 'ChoiceOfFunctions', as 'ArrayRef[FunctionName]';
coerce 'ChoiceOfFunctions', from 'FunctionName', via { [ $_ ] };
coerce 'ChoiceOfFunctions', from 'Undef', via { [] };

has qw(name is ro isa Str default) => "??";
has qw(validators is ro isa ChoiceOfFunctions coerce 1 default), sub { [] };
has qw(context is rw isa Term::ReadLine::CLISH::Command);
has qw(required is ro isa Bool default 0);
has qw(tag_optional is ro isa Bool default 0);
has qw(help is ro isa Str default ??);

has qw(default is ro isa Str default ??);

__PACKAGE__->meta->make_immutable;

sub stringify {
    my $this = shift;

    return "ARG[" . $this->name . "]";
}

sub with_default {
    my $this  = shift;
    my $obj   = bless { %$this }, ref $this;
    my $value = shift;

    $obj->value( $value );

    return $obj;
}

sub add_to_hashref_with_value {
    my $this = shift;
    my $ref  = shift; croak unless ref $ref eq "HASH";
    my $obj  = $this->with_value( @_ );

    return $ref->{ $obj->name } = $obj;
}

sub with_context {
    my $this = shift;
    my $obj  = bless { %$this }, ref $this;
    my $ctx  = shift;

    $obj->context( $ctx );

    return $obj;
}

sub validate {
    my ($this, $that) = @_;
    my $validators = $this->validators;

    # If there are no validators, then we can't accept arguments for this tag
    return if @$validators == 0;

    my $context = $this->context or die "my context is missing";

    for my $v (@$validators) {
        my $r = $context->$v( $that );

        return $r if $r;
    }

    return;
}

memoize( 'validate' );

1;
