module dmocks.Mocks;

import dmocks.MockObject;
import dmocks.Factory;
import dmocks.Repository; 
import dmocks.Util; 
import std.gc;
import std.variant;

version (MocksDebug) import std.stdio;
version (MocksTest) import std.stdio;

/++
    A class through which one creates mock objects and manages expected calls. 
 ++/
public class Mocker {
    private MockRepository _repository;

    public {
        this () {
            _repository = new MockRepository();
        }

        /** 
         * Stop setting up expected calls. Any calls after this point will
         * be verified against the expectations set up before calling Replay.
         */
        void Replay () {
            _repository.Replay();
        }
        alias Replay replay;

        /**
         * Record method calls starting at this point. These calls are not
         * checked against existing expectations; they create new expectations.
         */
        void Record () {
            _repository.BackToRecord();
        }
        alias Record record;

        /**
         * Check to see if there are any expected calls that haven't been
         * matched with a real call. Throws an ExpectationViolationException
         * if there are any outstanding expectations.
         */
        void Verify () {
            _repository.Verify();
        }
        alias Verify verify;

        /**
         * By default, all expectations are unordered. If I want to require that
         * one call happen immediately after another, I call Mocker.Ordered, make
         * those expectations, and call Mocker.Unordered to avoid requiring a
         * particular order afterward.
         *
         * Currently, the support for ordered expectations is rather poor. It works
         * well enough for expectations with a constant number of repetitions, but
         * with a range, it tends to fail: once you call one method the minimum number
         * of times, you can omit that method in subsequent invocations of the set.
         */
        void Ordered () {
            _repository.Ordered(true);
        }

        void Unordered () {
            _repository.Ordered(false);
        }

        /** Get a mock object of the given type. */
        T Mock (T) () {
            return MockFactory.Mock!(T)(_repository);
            /*
            static assert (is(T == class) || is(T == interface), 
                    "only classes and interfaces can be mocked");
            // WARNING: THIS IS UGLY AND IMPLEMENTATION-SPECIFIC
            void*[] mem = cast(void*[])malloc(__traits(classInstanceSize, Mocked!(T)));
            mem[0] = (Mocked!(T)).classinfo.vtbl.ptr;
            setTypeInfo(typeid(Mocked!(T)), mem.ptr);

            version(MocksDebug) writefln("set the vtbl ptr");

            auto t = cast(Mocked!(T))(mem.ptr);

            version(MocksDebug) writefln("casted");

            assert (t !is null);
            t._owner = _repository;

            version(MocksDebug) writefln("set repository");

            T retval = cast(T)t;

            version(MocksDebug) writefln("cast to T");
            version(MocksDebug) assert (retval !is null);
            version(MocksDebug) writefln("returning");
            return retval;
            */
        }
        alias Mock mock;

        /**
         * Only for non-void methods. Start an expected call; this returns
         * an object that allows you to set various properties on the call,
         * such as return value and number of repetitions.
         *
         * Examples:
         * ---
         * Mocker m = new Mocker;
         * Object o = m.Mock!(Object);
         * m.Expect(o.toString).Return("hello?");
         * ---
         */
        ExternalCall Expect (T) (T ignored) {
            return LastCall();
        }
        alias Expect expect;

        /**
         * For void and non-void methods. Start an expected call; this returns
         * an object that allows you to set various properties on the call,
         * such as return value and number of repetitions.
         *
         * Examples:
         * ---
         * Mocker m = new Mocker;
         * Object o = m.Mock!(Object);
         * o.toString;
         * m.LastCall().Return("hello?");
         * ---
         */
        ExternalCall LastCall () {
            return new ExternalCall(_repository.LastCall());
        }
        alias LastCall lastCall;

        /**
         * Set up a result for a method, but without any backend accounting for it.
         * Things where you want to allow this method to be called, but you aren't
         * currently testing for it.
         */
        ExternalCall Allowing (T) (T ignored) {
            return LastCall().RepeatAny;
        }

        /** Ditto */
        ExternalCall Allowing (T = void) () {
            return LastCall().RepeatAny();
        }

        /**
         * Do not require explicit return values for expectations. If no return
         * value is set, return the default value (null / 0 / nan, in most
         * cases). By default, if no return value, exception, delegate, or
         * passthrough option is set, an exception will be thrown.
         */
        void AllowDefaults () {
            _repository.AllowDefaults(true);
        }
    }
}

/++
   An ExternalCall allows you to set up various options on a Call,
   such as return value, number of repetitions, and so forth.
   Examples:
   ---
   Mocker m = new Mocker;
   Object o = m.Mock!(Object);
   o.toString;
   m.LastCall().Return("Are you still there?").Repeat(1, 12);
   ---
++/
public class ExternalCall {
   private ICall _call;

   this (ICall call) {
       _call = call;
   }

   // TODO: how can I get validation here that the type you're
   // inserting is the type expected before trying to execute it?
   // Not really an issue, since it'd be revealed in the space
   // of a single test.
   /**
    * Set the return value of call.
    * Params:
    *     value = the value to return
    */
   ExternalCall Return (T)(T value) {
       _call.ReturnValue(Variant(value));
       return this;
   }
   alias Return returnValue;

   /**
    * The arguments for this call will be ignored.
    */
   ExternalCall IgnoreArguments () {
       _call.IgnoreArguments = true;
       return this;
   }
   alias IgnoreArguments ignoreArguments;

   /**
    * This call must be repeated at least min times and can be repeated at
    * most max times.
    */
   ExternalCall Repeat (int min, int max) {
       if (min > max) {
           throw new InvalidOperationException("The specified range is invalid.");
       }
       _call.Repeat(Interval(min, max));
       return this;
   }
   alias Repeat repeat;

   /**
    * This call must be repeated exactly i times.
    */
   ExternalCall Repeat (int i) {
       _call.Repeat(Interval(i, i));
       return this;
   }

   /**
    * This call can be repeated any number of times.
    */
   ExternalCall RepeatAny () {
       return Repeat(0, int.max);
   }
   alias RepeatAny repeatAny;

   /**
    * When the method is executed (with matching arguments), execute the
    * given delegate. The delegate's signature must match the signature
    * of the called method. If it does not, an exception will be thrown.
    * The called method will return whatever the given delegate returns.
    * Examples:
    * ---
    * m.Expect(myObj.myFunc(0, null, null, 'a')
    *     .IgnoreArguments()
    *     .Do((int i, string s, Object o, char c) { return -1; });
    * ---
    */
   ExternalCall Do (T, U...)(T delegate(U) action) {
       Variant a = Variant(action);
       _call.Action(a);
       return this;
   }
   alias Do action;

   /**
    * When the method is called, throw the given exception. If there are any
    * actions specified (via the Do method), they will not be executed.
    */
   ExternalCall Throw (Exception e) {
       _call.Throw(e);
       return this;
   }
   alias Throw throwException;

   /**
    * Instead of returning or throwing a given value, pass the call through to
    * the base class. This is dangerous -- the private fields of the class may
    * not be set up properly, so only use this when the function does not depend
    * on these fields. Things such as using Object's toHash and opEquals when your
    * class doesn't override them and you use associative arrays.
    */
   ExternalCall PassThrough () {
       _call.SetPassThrough();
       return this;
   }
}

version (MocksTest) {
    class Templated(T) {}
    interface IM {
        void bar ();
    }

    class ConstructorArg {
        this (int i) {}
    }

    unittest {
        writef("nontemplated mock unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        (new Mocker()).Mock!(Object);
    }

    unittest {
        writef("templated mock unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        (new Mocker()).Mock!(Templated!(int));
    }

    unittest {
        writef("templated mock unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        (new Mocker()).Mock!(IM);
    }

    unittest {
        writef("execute mock method unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        auto r = new Mocker();
        auto o = r.Mock!(Object);
        o.toString();
        assert (r.LastCall()._call !is null);
    }

    unittest {
        writef("constructor argument unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        auto r = new Mocker();
        r.Mock!(ConstructorArg);
    }

    unittest {
        writef("collect test...");
        scope(success) writefln("success");
        scope(failure) writefln("failure");

        Mocker m = new Mocker();
        m.Mock!(Object);
        fullCollect();
    }

    unittest {
        writef("LastCall test...");
        scope(success) writefln("success");
        scope(failure) writefln("failure");

        Mocker m = new Mocker();
        Object o = m.Mock!(Object);
        o.print;
        auto e = m.LastCall;

        assert (e._call !is null);
    }

    unittest {
        writef("return a value test...");
        scope(success) writefln("success");
        scope(failure) writefln("failure");

        Mocker m = new Mocker();
        Object o = m.Mock!(Object);
        o.toString;
        auto e = m.LastCall;

        assert (e._call !is null);
        e.Return("frobnitz");
    }

    unittest {
        writef("expect test...");
        scope(success) writefln("success");
        scope(failure) writefln("failure");

        Mocker m = new Mocker();
        Object o = m.Mock!(Object);
        m.Expect(o.toString).Repeat(0).Return("mrow?");
        m.Replay();
        try {
            o.toString;
        } catch (Exception e) {}
    }

    unittest {
        writef("repeat single test...");
        scope(success) writefln("success");
        scope(failure) writefln("failure");

        Mocker m = new Mocker();
        Object o = m.Mock!(Object);
        m.Expect(o.toString).Repeat(2).Return("foom?");

        m.Replay();

        o.toString;
        o.toString;
        try {
            o.toString;
            assert (false, "expected exception not thrown");
        } catch (ExpectationViolationException) {}
    }

    unittest {
        writef("repository match counts unit test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        auto r = new Mocker();
        auto o = r.Mock!(Object);
        o.toString;
        r.LastCall().Repeat(2, 2).Return("mew.");
        r.Replay();
        try {
            r.Verify();
            assert (false, "expected exception not thrown");
        } catch (ExpectationViolationException) {}
    }

    unittest {
        writef("delegate payload test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        bool calledPayload = false;
        Mocker r = new Mocker();
        auto o = r.Mock!(Object);

        o.print;
        r.LastCall().Do({ calledPayload = true; });
        r.Replay();

        o.print;
        assert (calledPayload);
    }

    unittest {
        writef("exception payload test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);

        string msg = "divide by cucumber error";
        o.print;
        r.LastCall().Throw(new Exception(msg));
        r.Replay();

        try {
            o.print;
            assert (false, "expected exception not thrown");
        } catch (Exception e) {
            // Careful -- assertion errors derive from Exception
            assert (e.msg == msg, e.msg);
        }
    }

    class HasPrivateMethods {
        protected void method () {}
    }

    unittest {
        writef("passthrough test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        o.toString;
        r.LastCall().PassThrough();

        r.Replay();
        string str = o.toString;
        assert (str == "dmocks.MockObject.Mocked!(Object).Mocked", str);
    }

    unittest {
        writef("associative arrays test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.Expect(o.toHash()).PassThrough().RepeatAny;
        r.Expect(o.opEquals(null)).IgnoreArguments().PassThrough().RepeatAny;

        r.Replay();
        int[Object] i;
        i[o] = 5;
        int j = i[o];
    }

    unittest {
        writef("ordering in order test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.Ordered;
        r.Expect(o.toHash).Return(5);
        r.Expect(o.toString).Return("mow!");

        r.Replay();
        o.toHash;
        o.toString;
        r.Verify;
    }

    unittest {
        writef("ordering not in order test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.Ordered;
        r.Expect(o.toHash).Return(5);
        r.Expect(o.toString).Return("mow!");

        r.Replay();
        try {
            o.toString;
            o.toHash;
            assert (false);
        } catch (ExpectationViolationException) {}
    }

    unittest {
        writef("ordering interposed test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.Ordered;
        r.Expect(o.toHash).Return(5);
        r.Expect(o.toString).Return("mow!");
        r.Unordered;
        o.print;

        r.Replay();
        o.toHash;
        o.print;
        o.toString;
    }

    unittest {
        writef("allowing test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.Allowing(o.toString).Return("foom?");

        r.Replay();
        o.toString;
        o.toString;
        o.toString;
        r.Verify;
    }

    unittest {
        writef("nothing for method to do test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        try {
            Mocker r = new Mocker();
            auto o = r.Mock!(Object);
            r.Allowing(o.toString);

            r.Replay();
            assert (false, "expected a mocks setup exception");
        } catch (MocksSetupException e) {
        }
    }

    unittest {
        writef("allow defaults test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");

        Mocker r = new Mocker();
        auto o = r.Mock!(Object);
        r.AllowDefaults;
        r.Allowing(o.toString);

        r.Replay();
        assert (o.toString == string.init);
    }

    interface IFace {
        void foo (string s);
    }

    class Smthng : IFace {
        void foo (string s) { }
    }

    unittest {
        writefln("going through the guts of Smthng.");
        auto foo = new Smthng();
        auto guts = *(cast(int**)&foo);
        auto len = __traits(classInstanceSize, Smthng) / size_t.sizeof; 
        auto end = guts + len;
        for (; guts < end; guts++) {
            writefln("\t%x", *guts);
        } 
    }

    unittest {
        writef("mock interface test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        auto r = new Mocker;
        IFace o = r.Mock!(IFace);
        version(MocksDebug) writefln("about to call once...");
        o.foo("hallo");
        r.Replay;
        version(MocksDebug) writefln("about to call twice...");
        o.foo("hallo");
        r.Verify;
    }

    unittest {
        writef("cast mock to interface test...");
        scope(failure) writefln("failed");
        scope(success) writefln("success");
        auto r = new Mocker;
        IFace o = r.Mock!(Smthng);
        version(MocksDebug) writefln("about to call once...");
        o.foo("hallo");
        r.Replay;
        version(MocksDebug) writefln("about to call twice...");
        o.foo("hallo");
        r.Verify;
    }

    void main () {
        writefln("All tests pass.");
    }

}