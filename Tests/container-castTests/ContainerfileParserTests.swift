import Foundation
import Testing

@testable import container_cast

@Suite("ContainerfileParser")
struct ContainerfileParserTests {

    @Test("Parses basic directives")
    func basicDirectives() {
        let input = """
            FROM alpine:3.19
            RUN apk add curl
            CMD ["echo", "hello"]
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives.count == 3)
        #expect(directives[0].keyword == "FROM")
        #expect(directives[0].arguments == "alpine:3.19")
        #expect(directives[1].keyword == "RUN")
        #expect(directives[1].arguments == "apk add curl")
        #expect(directives[2].keyword == "CMD")
        #expect(directives[2].arguments == "[\"echo\", \"hello\"]")
    }

    @Test("Skips comments and blank lines")
    func commentsAndBlanks() {
        let input = """
            # This is a comment
            FROM ubuntu

            # Another comment
            RUN apt-get update
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives.count == 2)
        #expect(directives[0].keyword == "FROM")
        #expect(directives[1].keyword == "RUN")
    }

    @Test("Handles line continuations")
    func lineContinuations() {
        let input = """
            FROM alpine
            RUN apk add \\
                curl \\
                jq
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives.count == 2)
        #expect(directives[1].keyword == "RUN")
        #expect(directives[1].arguments.contains("curl"))
        #expect(directives[1].arguments.contains("jq"))
    }

    @Test("Parses all known directives")
    func allDirectives() {
        let input = """
            FROM alpine
            ARG VERSION=1.0
            RUN echo test
            COPY . /app
            ADD archive.tar /opt
            ENV MY_VAR=value
            EXPOSE 8080
            ENTRYPOINT ["/bin/sh"]
            CMD ["-c", "echo hi"]
            WORKDIR /app
            USER nobody
            LABEL version="1.0"
            VOLUME /data
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives.count == 13)

        let keywords = directives.map(\.keyword)
        #expect(keywords.contains("FROM"))
        #expect(keywords.contains("ARG"))
        #expect(keywords.contains("RUN"))
        #expect(keywords.contains("COPY"))
        #expect(keywords.contains("ADD"))
        #expect(keywords.contains("ENV"))
        #expect(keywords.contains("EXPOSE"))
        #expect(keywords.contains("ENTRYPOINT"))
        #expect(keywords.contains("CMD"))
        #expect(keywords.contains("WORKDIR"))
        #expect(keywords.contains("USER"))
        #expect(keywords.contains("LABEL"))
        #expect(keywords.contains("VOLUME"))
    }

    @Test("Records correct line numbers")
    func lineNumbers() {
        let input = """
            FROM alpine
            # comment
            RUN echo test
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives[0].lineNumber == 1)
        #expect(directives[1].lineNumber == 3)
    }

    @Test("Case-insensitive directive matching")
    func caseInsensitive() {
        let input = """
            from alpine
            run echo test
            cmd ["sh"]
            """

        let directives = ContainerfileParser.parse(input)
        #expect(directives.count == 3)
        #expect(directives[0].keyword == "FROM")
        #expect(directives[1].keyword == "RUN")
        #expect(directives[2].keyword == "CMD")
    }

    @Test("Empty input returns empty list")
    func emptyInput() {
        let directives = ContainerfileParser.parse("")
        #expect(directives.isEmpty)
    }

    @Test("Multi-stage build")
    func multiStage() {
        let input = """
            FROM golang:1.21 AS builder
            WORKDIR /src
            COPY . .
            RUN go build -o /app

            FROM alpine:3.19
            COPY --from=builder /app /usr/local/bin/app
            CMD ["/usr/local/bin/app"]
            """

        let directives = ContainerfileParser.parse(input)
        let fromDirectives = directives.filter { $0.keyword == "FROM" }
        #expect(fromDirectives.count == 2)
        #expect(fromDirectives[0].arguments == "golang:1.21 AS builder")
        #expect(fromDirectives[1].arguments == "alpine:3.19")
    }
}

@Suite("MountSpec parsing")
struct MountSpecTests {

    @Test("Valid mount parses correctly")
    func validMount() throws {
        let mount = try MountSpec(parsing: "/tmp:/data")
        #expect(mount.source == "/tmp")
        #expect(mount.destination == "/data")
    }

    @Test("Rejects missing colon")
    func missingColon() {
        #expect(throws: ContainerCastError.self) {
            try MountSpec(parsing: "/tmp/data")
        }
    }
}

@Suite("MemorySize parsing")
struct MemorySizeTests {

    @Test("Parses megabytes with M suffix")
    func megabytes() {
        let size = MemorySize(argument: "512M")
        #expect(size?.megabytes == 512)
    }

    @Test("Parses megabytes with MB suffix")
    func megabytesMB() {
        let size = MemorySize(argument: "256MB")
        #expect(size?.megabytes == 256)
    }

    @Test("Parses megabytes with MiB suffix")
    func megabytesMiB() {
        let size = MemorySize(argument: "128MiB")
        #expect(size?.megabytes == 128)
    }

    @Test("Parses gigabytes with G suffix")
    func gigabytes() {
        let size = MemorySize(argument: "2G")
        #expect(size?.megabytes == 2048)
    }

    @Test("Parses gigabytes with GB suffix")
    func gigabytesGB() {
        let size = MemorySize(argument: "1GB")
        #expect(size?.megabytes == 1024)
    }

    @Test("Parses gigabytes with GiB suffix")
    func gigabytesGiB() {
        let size = MemorySize(argument: "4GiB")
        #expect(size?.megabytes == 4096)
    }

    @Test("Parses bare number as megabytes")
    func bareNumber() {
        let size = MemorySize(argument: "2048")
        #expect(size?.megabytes == 2048)
    }

    @Test("Case insensitive")
    func caseInsensitive() {
        #expect(MemorySize(argument: "512m")?.megabytes == 512)
        #expect(MemorySize(argument: "1g")?.megabytes == 1024)
        #expect(MemorySize(argument: "1gb")?.megabytes == 1024)
    }

    @Test("Trims whitespace")
    func whitespace() {
        let size = MemorySize(argument: " 512M ")
        #expect(size?.megabytes == 512)
    }

    @Test("Rejects zero")
    func zero() {
        #expect(MemorySize(argument: "0M") == nil)
        #expect(MemorySize(argument: "0G") == nil)
    }

    @Test("Rejects negative")
    func negative() {
        #expect(MemorySize(argument: "-1M") == nil)
        #expect(MemorySize(argument: "-512") == nil)
    }

    @Test("Rejects garbage")
    func garbage() {
        #expect(MemorySize(argument: "abc") == nil)
        #expect(MemorySize(argument: "") == nil)
        #expect(MemorySize(argument: "M") == nil)
        #expect(MemorySize(argument: "G") == nil)
    }

    @Test("Description formats correctly")
    func description() {
        #expect(MemorySize(argument: "512M")?.description == "512M")
        #expect(MemorySize(argument: "1G")?.description == "1G")
        #expect(MemorySize(argument: "1536M")?.description == "1536M")
        #expect(MemorySize(argument: "2048M")?.description == "2G")
    }
}
