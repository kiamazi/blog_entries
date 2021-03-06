---
created: 2015-09-03
---

# Journey to Neovim: MessagePack Decoder

Recap: I'm playing with a rewrite of [](cpan:Vim-X) for 
[neovim](http://neovim.io). For that to happen, I have to
write an encoder and a decoder for [MessagePack](http://msgpack.org),
the weirdo binary encoding its RPC API is using. [Last time](blog:neovim-part-1), 
I've dealt with the encoder. This time around, I'm tackling the decoder.

At its core, the decoding is not harder than the encoding -- it's merely
the reverse operation. But there is one detail that brings some spice to the salsa:
whereas for the encoding we have the struct we're operating on from the get go,
for the decoding we're not so lucky, and we have to be prepared for a stream of 
bytes trickling in. And MessagePack encoding doesn't come with a header that
tells us how many bytes the incoming structure will have, so we don't know when that stream will
be done either.

Mind you, there are several ways to deal with such a streaming input. One way would be to accumulate
the incoming data in a buffer and try to decode a struct each time a new byte is added to the head.
If we succeed, hurray, if we don't we revert and repeat the process the next time new bytes come in.
It'd work, but I'm sure you'll agree it lacks... style.

Sometime much cooler would be to analyse each byte as they come in, and adapt the reader such that it'll
treat the next bytes in the right context. For example, if we get a first byte that tells us the structure is
an array of 3 elements, then we want the reader to prepare itself for the arrival of 3 new structures, and then
put them together in the final array. In effect, we want to implement a state machine. Well, *I* want, that is. 
By now, I suspect dread is slowly creeping up your spine, and what you want is to know
how dark and deep down the rabbit hole this blog entry will go.

The answer, I'm afraid, is down, down, down all the way to higher function programming.

(that, by the way, is your clue to reach out for the bottle of aspirins, or run away. Your choice)

## High level description

So, what do I mean by higher-function programming? I mean that I'll be using functions that,
upon reading an upcoming byte, will generate a new function that takes in a subsequent
byte, and will output, yes, yet another function that has the same behavior, et cetera until
the glorious moment where a structure is finally decoded and will be returned.

Now, let's try to explain that again in a way that makes the room spin slightly less
sharply.

Assume that we have a code ref pointing to a function that takes one byte.

```perl
my $gen_next = sub { ... };
```

Assuming that this sub is a reader function as described above, then the next time a byte comes in,
we can do

```perl
my $subsequent_gen_next = $gen_next->($byte);
```

Now, if all it took was 2 bytes to get the full structure, `$subsequent_gen_next` will contain it.
If we still need more, then we'll have to continue playing that game a third time:

```perl
my $subsubsequent_gen_next = $subsequent_gen_next->($byte);
```

Of course, we have loops to take care of this. Assuming that the reader functions always
return a code ref when more bytes required to decode the structure, and the structure when it's done, then 
reading a stream amounts to:

```perl
use Data::Printer;

my $gen_next = $mysterious_original_sub;

while( my $byte = $stream->read_next ) {
    $gen_next = $gen_next->($byte);

    next if ref $gen_next eq 'CODE';

    say "GOT ONE STRUCT!";
    p $gen_next;
    $gen_next = $mysterious_original_sub;
}
```

See? That's not *that* bad. We just have to figure out what hides behind that `$mysterious_original_sub`....


## Moose says 'High!'

Before diving into the generating functions, let's set the base for the decoder. 

```perl
package Decoder;

use 5.22.0;

use warnings;

use Moose;

use List::AllUtils qw/ reduce /;
use List::Gather;

use experimental 'signatures';

has buffer => (
    is      => 'rw',
    traits  => [ 'Array' ],
    default => sub { [] },
    handles => {
        has_buffer    => 'count',
        next          => 'shift',
        all           => 'elements',
        add_to_buffer => 'push',
    },
);

after all => sub($self) {
    $self->buffer([]);
};

has gen_next => (
    is =>  'rw',
    clearer => 'clear_gen_next',
    default => sub { 
        gen_new_value();
    }

);

sub is_gen($val) { ref $val eq 'CODE' and $val }

sub read($self,@values) {

    $self->add_to_buffer( gather {
        $self->gen_next( 
            reduce {
                my $g = $a->($b);
                is_gen($g) or do { take $$g; gen_new_value() }
            } $self->gen_next => map { ord } map { split '' } @values
        );
    } );

}
```

The interface is pretty simple: bytes come in via `read()`, and as soon as a structure is decode, it get
pushed into the buffer. The innards of `read()` might look scary, but it's just a funky variation on the loop
we saw in the previous section. I swear.

Now, for that `gen_new_value()` function...

## High expectations

Following what we said so far, `gen_new_value()` will generate the function that will process
the first byte from a new structure. Which will mostly be "if the byte is in that range, what's coming
is a fixed array, so use that piece of code, if the byte is in that other range, what's coming is 
a fixed integer, so use that *other* piece of code". Doesn't that sound familiar to what we did in the encoding process?
It sure does, so let's use the same tactic here:

```perl
sub gen_new_value { 
    sub ($byte) { $MessagePackGenerator->assert_coerce($byte); } 
}
```


Fine. But we only delayed the inevitable. What about `$MessagePackGenerator`?

## Hijinx

We'll use pretty much the same technique as in the previous blog entry. But since we
know we'll be coercing from bytes, we can simplify a little bit the main type and only require it to
be a ref (more specifically, a coderef or a ref to the data structure) instead of a class.

```perl
use Types::Standard qw/ Ref /;
use Type::Tiny;

use experimental 'postderef';

my $MessagePackGenerator  = Type::Tiny->new(
    parent => Ref,
    name   => 'MessagePackGenerator',
);

my @msgpack_types = (
      # name             # range         # generating function
    [ PositiveFixInt => [    0, 0x7f ], \&gen_positive_fixint ],
    [ FixArray       => [ 0x90, 0x9f ], \&gen_fixarray ],
    [ FixMap         => [ 0x80, 0x8f ], \&gen_fixmap ],
);

$MessagePackGenerator = $MessagePackGenerator->plus_coercions(
    map {
        my( $min, $max ) = $_->[1]->@*;
        Type::Tiny->new(
            parent     => Int,
            name       => $_->[0],
            constraint => sub { $_ >= $min and $_ <= $max },
        ) => $_->[2]  
    } @msgpack_types
);
```

Boom. Types are set up. But still, the generation functions are yet to be defined... 

## High time

Those generation functions are the hardest part of the puzzle. For some types, they are not too bad. For example, the 
positive fixed int is pretty easy:

```perl
sub gen_positive_fixint { \$_  }
```

(remember, we return a reference to the value instead of the value itself because we need variables of the `$MessagePackGenerator` type to be
references.)

We it get funnier is for types like array:

```perl
sub gen_fixarray {
    gen_array( $_ - 0x90 );
}

sub gen_array($size) {

    return \[] unless $size;

    my @array;

    @array = map { gen_new_value() } 1..$size;

    sub($byte) {
        $_ = $_->($byte) for first { is_gen($_) } @array;

        ( any { is_gen($_) } @array ) ? __SUB__ : \[ map { $$_ } @array ];
    }
}
```

The way I implemented `gen_array()` might be, ah, let's say different. But let me assure you, it's roughly equivalent to the more
bening:

```perl
sub gen_array($size) {

    return \[] unless $size;

    my @array;
    my $gen = gen_new_value();

    sub($byte) {
        $gen = $gen->($byte);

        unless( is_gen($gen) ) {
            push @array, $gen;

            return \@array if @array == $size;
    
            $gen = gen_new_value;
        }

        return __SUB__;
    }
}
```

The good news is that with `gen_array` implemented, all
other arrays and hashes are only a few lines on top of its core:

```perl
sub gen_fixmap {
    gen_map($_ - 0x80);
}

sub gen_map($size) {
    return \{} unless $size;

    my $gen = gen_array( 2*$size );

    sub($byte) {
        $gen = $gen->($byte);
        is_gen( $gen ) ? __SUB__ : \{ @$$gen };
    }
}
```

## High ho!

And, guess what, that's all the little pieces that we need. 

```perl
my $decoder = Decoder->new;
$decoder->read( join '', map { chr } 0x83, 1, 2, 3, 4, 5, 6 );

use Data::Printer;
say $decoder->has_buffer;   # will print '1'
p $decoder->next;           # will print { 1 => 2, 3 => 4, 5 => 6} 
```









