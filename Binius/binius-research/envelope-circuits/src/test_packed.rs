use binius_field::{
    PackedFieldIndexable, PackedField,
    arch::OptimalUnderlier,
    as_packed_field::PackedType,
};
use binius_m3::builder::B128;

fn check<P: PackedFieldIndexable>() {
    println!("PackedFieldIndexable IS implemented for P");
}

fn main() {
    type P = PackedType<OptimalUnderlier, B128>;
    println!("OptimalUnderlier size: {} bytes", std::mem::size_of::<OptimalUnderlier>());
    println!("P type name: {}", std::any::type_name::<P>());
    println!("P::LOG_WIDTH = {}", P::LOG_WIDTH);

    check::<P>();

    let is_indexable = binius_field::packed_extension::is_packed_field_indexable::<P>();
    println!("Runtime hack says is_packed_field_indexable = {}", is_indexable);
}
