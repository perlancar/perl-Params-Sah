package Params::Sah;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Carp;
use Data::Dmp qw(dmp);

use Exporter qw(import);
our @EXPORT_OK = qw(gen_validator);

our $DEBUG;

sub gen_validator {
    require Data::Sah;

    state $sah = Data::Sah->new;
    state $plc = $sah->get_compiler('perl');

    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $opts->{on_invalid} //= 'croak';
    croak "Invalid on_invalid value, must be: croak|carp|warn|die|bool|str"
        unless $opts->{on_invalid} =~ /\A(croak|carp|warn|die|bool|str)\z/;

    my %schemas;
    if ($opts->{named}) {
        %schemas = @_;
        for (keys %schemas) {
            croak "Invalid argument name, must be alphanums only"
                unless /\A[A-Za-z_]\w*\z/;
        }
    } else {
        my $i = 0;
        %schemas = map {$i++ => $_} @_;
    }

    my $src = '';

    my $i = 0;
    my %mentioned_mods;
    my %mentioned_vars;

    # currently prototype won't force checking
    if ($opts->{named}) {
        $src .= "sub(\\%) {\n";
    } else {
        $src .= "sub(\\@) {\n";
    }

    $src .= "    my \$_ps_args = shift;\n";
    $src .= "    my \$_ps_res;\n" unless $opts->{on_invalid} eq 'bool';

    for my $argname (sort keys %schemas) {
        $src .= "\n\n    ### validating $argname:\n";
        my ($argterm, $data_name);
        if ($opts->{named}) {
            $argterm = '$_ps_args->{'.dmp($argname).'}';
            $data_name = $argname;
        } else {
            $argterm = '$_ps_args->['.$argname.']';
            $data_name = "arg$argname";
        }
        my $return_type = $opts->{on_invalid} eq 'bool' ? 'bool' : 'str';
        my $cd = $plc->compile(
            data_name    => $data_name,
            data_term    => $argterm,
            err_term     => '$_ps_res',
            schema       => $schemas{$argname},
            return_type  => $return_type,
            indent_level => 1,
        );
        for my $mod (sort keys %{ $cd->{module_statements} }) {
            next if $mentioned_mods{$mod}++;
            my $stmt = $cd->{module_statements}{$mod};
            $src .= "    $stmt->[0] $mod".
                ($stmt->[1] && @{ $stmt->[1] } ?
                     " ".join(", ", @{ $stmt->[1] }) : "").";\n";
        }
        for my $mod (@{ $cd->{modules} }) {
            next if $cd->{module_statements}{$mod};
            (my $mod_pm = $mod) =~ s!::!/!g; $mod_pm .= ".pm";
            next if $mentioned_mods{$mod}++;
            require $mod_pm;
        }
        for my $var (sort keys %{$cd->{vars}}) {
            next if $mentioned_vars{$var}++;
            my $val = $cd->{vars}{$var};
            $src .= "    my \$$var" . (defined($val) ? " = ".dmp($val) : "").
                ";\n";
        }
        if ($opts->{on_invalid} =~ /\A(croak|carp|warn|die)\z/) {
            my $stmt = $opts->{on_invalid} =~ /\A(croak|carp)\z/ ?
                "Carp::$opts->{on_invalid}" : $opts->{on_invalid};
            $src .= "    $stmt(\"$data_name: \$_ps_res\") ".
                "if !($cd->{result});\n";
        } else {
            if ($return_type eq 'str') {
                $src .= "    return \"$data_name: \$_ps_res\" ".
                    "if !($cd->{result});\n";
            } else {
                $src .= "    return 0 if !($cd->{result});\n";
            }
        }
        $i++;
    } # for $argname

    if ($opts->{on_invalid} eq 'bool') {
        $src .= "    return 1\n";
    } elsif ($opts->{on_invalid} eq 'str') {
        $src .= "    return '';\n";
    } else {
        $src .= "    return;\n";
    }

    $src .= "\n};";
    if ($DEBUG) {
        require String::LineNumber;
        say "DEBUG: Validator code:\n" . String::LineNumber::linenum($src);
    }

    my $code = eval $src;
    $@ and die
        "BUG: Can't compile validator code: $@\nValidator code: $code\n";
    $code;
}

1;
# ABSTRACT: Validate method/function parameters using Sah schemas

=head1 SYNOPSIS

 use Params::Sah qw(gen_validator);

 # for subroutines that accept positional parameters
 sub mysub1 {
     state $validator = gen_validator('str*', 'int');
     $validator->(\@_);
 }

 # for subroutines that accept named parameters
 sub mysub2 {
     my %args = @_;

     state $validator = gen_validator({named=>1}, name=>'str*', age=>'int');
     $validator->(\%args);
 }

Examples for more complex schemas:

 gen_validator(
     {named => 1},
     name => ['str*', min_len=>4, match=>qr/\S/],
     age  => ['int', min=>17, max=>120],
 );

Validator generation options:

 # default is to 'croak', valid values include: carp, die, warn, bool, str
 gen_validator({on_invalid=>'croak'}, ...);


=head1 DESCRIPTION

This module provides a way for functions to validate their parameters using
L<Sah> schemas.

The interface is rather different than L<Params::Validate> because it returns a
validator I<code> instead of directly validating parameters. The returned
validator code is the actual routine that performs parameters checking. This is
done for performance reason. For efficiency, you need to cache this validator
code instead of producing them at each function call, thus the use of C<state>
variables.

Performance is faster than Params::Validate, since you can avoid recompiling
specification or copying array/hash twice. Sah also provides a rich way to
validate data structures.


=head1 FUNCTIONS

None exported by default, but exportable.

=head2 gen_validator([\%opts, ] ...) => code

Generate code for subroutine validation. It accepts an optional hashref as the
first argument for options. The rest of the arguments are Sah schemas that
corresponds to the function parameter in the same position, i.e. the first
schema will validate the function's first argument, and so on. Example:

 gen_validator('schema1', 'schema2', ...);
 gen_validator({option=>'val', ...}, 'schema1', 'schema2', ...);

Will return a coderef which is the validator code. The code accepts a hashref
(usually C<< \@_ >>).

Known options:

=over

=item * named => bool (default: 0)

If set to true, it means we are generating validator for subroutine that accepts
named parameters (e.g. C<< f(name=>'val', other=>'val2') >>) instead of
positional (e.g. C<< f('val', 'val2') >>). The validator will accept the
parameters as a hashref. And the arguments of C<gen_validator> are assumed to be
a hash of parameter names and schemas instead of a list of schemas, for example:

 gen_validator({named=>1}, arg1=>'schema1', arg2=>'schema2', ...);

=item * on_invalid => str (default: 'croak')

What should the validator code do when function parameters are invalid? The
default is to croak (see L<Carp>) to report error to STDERR from the caller
perspective. Other valid choices include: C<warn>, C<carp>, C<die>, C<bool>
(return false on invalid, or true on valid), C<str> (return an error message on
invalid, or empty string on valid).

=back


=head1 PERFORMANCE NOTES

Sample benchmark against Params::Validate:

#EXAMPLE: devscripts/bench

Sample benchmark result on my laptop:

                                   Rate P::V, named, str+int P::V, pos, str+int P::V, pos, str P::Sah, named, str+int P::Sah, pos, str+int P::Sah, pos, str
 P::V, named, str+int    77993.2+-0.14/s                   --             -28.3%         -72.3%                 -83.0%               -90.7%           -92.9%
 P::V, pos, str+int        108710+-140/s         39.38+-0.18%                 --         -61.4%                 -76.3%               -87.0%           -90.1%
 P::V, pos, str            281590+-530/s        261.04+-0.68%      159.03+-0.59%             --                 -38.6%               -66.4%           -74.4%
 P::Sah, named, str+int    458440+-180/s               487.8%      321.71+-0.57%   62.81+-0.31%                     --               -45.2%           -58.3%
 P::Sah, pos, str+int      837250+-880/s          973.5+-1.1%        670.2+-1.3%  197.33+-0.64%            82.63+-0.2%                   --           -23.9%
 P::Sah, pos, str       1.0997e+06+-24/s              1310.0%        911.6+-1.3%  290.54+-0.73%                 139.9%         31.35+-0.14%               --


=head1 FAQ

=head2 Why does the validator code accept arrayref/hashref instead of array/hash?

To be able to modify the original array/hash, e.g. set default value.

=head2 How to give default value to parameters?

By using the Sah C<default> clause:

 gen_validator(['str*', default=>'green']);

=head2 How do I see the validator code being generated?

Set C<$Params::Sah::DEBUG=1> before C<gen_validator()>, for example:

 use Params::Sah qw(gen_validator);

 $Params::Sah::DEBUG = 1;
 gen_validator('int*', 'str');

Sample output:

   1|sub(\@) {
   2|    my $_ps_args = shift;
   3|    my $_ps_res;
    |
    |
   6|    ### validating 0:
   7|    no warnings 'void';
   8|    my $_sahv_dpath = [];
   9|    Carp::croak("arg0: $_ps_res") if !(    # req #0
  10|    ((defined($_ps_args->[0])) ? 1 : (($_ps_res //= (@$_sahv_dpath ? '@'.join("/",@$_sahv_dpath).": " : "") . "Required but not specified"),0))
    |
  12|    &&
    |
  14|    # check type 'int'
  15|    ((Scalar::Util::Numeric::isint($_ps_args->[0])) ? 1 : (($_ps_res //= (@$_sahv_dpath ? '@'.join("/",@$_sahv_dpath).": " : "") . "Not of type integer"),0)));
    |
    |
  18|    ### validating 1:
  19|    Carp::croak("arg1: $_ps_res") if !(    # skip if undef
  20|    (!defined($_ps_args->[1]) ? 1 :
    |
  22|    (# check type 'str'
  23|    ((!ref($_ps_args->[1])) ? 1 : (($_ps_res //= (@$_sahv_dpath ? '@'.join("/",@$_sahv_dpath).": " : "") . "Not of type text"),0)))));
  24|    return;
    |
  26|};


=head1 SEE ALSO

L<Sah>, L<Data::Sah>

L<Params::Validate>

L<Perinci::Sub::Wrapper>, if you want to do more than parameter validation.

=cut
