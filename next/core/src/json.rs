//! JSON the way Swift's `JSONEncoder` writes it, so a file the new app saves is the file the Mac
//! app would have saved: `"key" : value` with two-space indents when pretty, whole numbers with
//! no ".0", and "/" escaped as "\/". Sorted keys come from serializing through
//! `serde_json::Value`, whose maps are ordered.

use serde::Serialize;
use serde_json::ser::{CompactFormatter, Formatter, PrettyFormatter};
use std::io::{self, Write};

struct Swift<F> {
    inner: F,
    pretty: bool,
}

impl<F: Formatter> Formatter for Swift<F> {
    fn begin_array<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.begin_array(w)
    }
    fn end_array<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.end_array(w)
    }
    fn begin_array_value<W: ?Sized + Write>(&mut self, w: &mut W, first: bool) -> io::Result<()> {
        self.inner.begin_array_value(w, first)
    }
    fn end_array_value<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.end_array_value(w)
    }
    fn begin_object<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.begin_object(w)
    }
    fn end_object<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.end_object(w)
    }
    fn begin_object_key<W: ?Sized + Write>(&mut self, w: &mut W, first: bool) -> io::Result<()> {
        self.inner.begin_object_key(w, first)
    }
    fn begin_object_value<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        w.write_all(if self.pretty { b" : " } else { b":" })
    }
    fn end_object_value<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
        self.inner.end_object_value(w)
    }
    fn write_f64<W: ?Sized + Write>(&mut self, w: &mut W, value: f64) -> io::Result<()> {
        if value.is_finite() && value.fract() == 0.0 && value.abs() < 1e15 {
            write!(w, "{}", value as i64)
        } else {
            self.inner.write_f64(w, value)
        }
    }
    fn write_string_fragment<W: ?Sized + Write>(&mut self, w: &mut W, fragment: &str) -> io::Result<()> {
        let mut parts = fragment.split('/');
        w.write_all(parts.next().unwrap_or("").as_bytes())?;
        for part in parts {
            w.write_all(b"\\/")?;
            w.write_all(part.as_bytes())?;
        }
        Ok(())
    }
}

fn write<T: Serialize + ?Sized, F: Formatter>(value: &T, inner: F, pretty: bool) -> serde_json::Result<String> {
    let mut out = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut out, Swift { inner, pretty });
    value.serialize(&mut ser)?;
    Ok(String::from_utf8(out).expect("serde_json writes UTF-8"))
}

/// `.prettyPrinted`, keys in the struct's order.
pub fn pretty<T: Serialize + ?Sized>(value: &T) -> serde_json::Result<String> {
    write(value, PrettyFormatter::with_indent(b"  "), true)
}

/// `[.prettyPrinted, .sortedKeys]`.
pub fn pretty_sorted<T: Serialize + ?Sized>(value: &T) -> serde_json::Result<String> {
    pretty(&serde_json::to_value(value)?)
}

/// One line, as the `.jsonl` files hold.
pub fn compact<T: Serialize + ?Sized>(value: &T) -> serde_json::Result<String> {
    write(value, CompactFormatter, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_what_swift_writes() {
        let v = serde_json::json!({"title": "a/b", "durationSeconds": 380.0, "start": 1.5, "id": "X"});
        assert_eq!(pretty_sorted(&v).unwrap(), "{\n  \"durationSeconds\" : 380,\n  \"id\" : \"X\",\n  \"start\" : 1.5,\n  \"title\" : \"a\\/b\"\n}");
        assert_eq!(compact(&serde_json::json!({"start": 0.0})).unwrap(), "{\"start\":0}");
        let back: serde_json::Value = serde_json::from_str(&pretty_sorted(&v).unwrap()).unwrap();
        assert_eq!(back["durationSeconds"].as_f64(), Some(380.0));
        assert_eq!(back["title"], "a/b");
    }
}
