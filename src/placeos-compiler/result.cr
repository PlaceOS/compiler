module PlaceOS::Compiler
  abstract struct Result
    abstract def exit_code : Int32
    abstract def output : String

    getter? success : Bool { exit_code == 0 }

    record Command < Result,
      exit_code : Int32,
      output : String

    record Build < Result,
      name : String,
      path : String,
      commit : String,
      repository : String,
      exit_code : Int32,
      output : String
  end
end
