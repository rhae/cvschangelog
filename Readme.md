# Motivation
At work we are still stuck with CVS.
That is not too bad. We have a workflow that suits us.
Until now we have used [cvschangelogbuilder](cvschangelogb.sourceforge.net)
to get an overview about the changes.
However in our repositories cvschangelogbuilder is not working
to my satisfaction. Sometimes it just stucks.
I don't know why. I have no skills in perl and on the otherside it looks
quite frumpy.

So here is my take to build a nice changelog.

# Requirements
- Tcl 8.6
- Tcl sqlite 3
- gnuplot

# Syntax
The command syntax is quite similar to cvschangelogbuilder.

