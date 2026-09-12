import OrderedIndex "../OrderedIndex";

var index = OrderedIndex.empty();
index := OrderedIndex.replace(index, OrderedIndex.join([OrderedIndex.keyPart("settled"), OrderedIndex.intPart(20), OrderedIndex.natPart(2)]), 2);
index := OrderedIndex.replace(index, OrderedIndex.join([OrderedIndex.keyPart("accepted"), OrderedIndex.intPart(10), OrderedIndex.natPart(1)]), 1);
index := OrderedIndex.replace(index, OrderedIndex.join([OrderedIndex.keyPart("accepted"), OrderedIndex.intPart(30), OrderedIndex.natPart(3)]), 3);

assert (OrderedIndex.size(index) == 3);

let accepted = OrderedIndex.prefix(index, OrderedIndex.keyPart("accepted"), 0, 10);
assert (accepted.size() == 2);
assert (accepted[0] == 1);
assert (accepted[1] == 3);

let acceptedPage = OrderedIndex.prefix(index, OrderedIndex.keyPart("accepted"), 1, 1);
assert (acceptedPage.size() == 1);
assert (acceptedPage[0] == 3);

index := OrderedIndex.replace(index, OrderedIndex.join([OrderedIndex.keyPart("accepted"), OrderedIndex.intPart(40), OrderedIndex.natPart(2)]), 2);
assert (OrderedIndex.size(index) == 3);

let acceptedAfterReplace = OrderedIndex.prefix(index, OrderedIndex.keyPart("accepted"), 0, 10);
assert (acceptedAfterReplace.size() == 3);
assert (acceptedAfterReplace[2] == 2);

let report = OrderedIndex.verify(index);
assert (report.ok);
